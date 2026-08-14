/**
 * Cloudflare Worker 智能边缘网关 (GTM-like 调度 + 边缘鉴权 + 故障秒级切流)
 */

import { Env, PUBLIC_PATHS, CORS_HEADERS } from './config';
import { verifyJWT } from './jwt';

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    // 1. 处理 CORS OPTIONS 预检请求 (0ms 边缘直接返回 204)
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: CORS_HEADERS,
      });
    }

    const url = new URL(request.url);

    // 2. 边缘鉴权拦截 (针对受保护的 /api/ 动态路由)
    const isPublic = PUBLIC_PATHS.some((path) => url.pathname.startsWith(path));
    let validatedUser: any = null;

    if (!isPublic && url.pathname.startsWith('/api/')) {
      const authHeader = request.headers.get('Authorization');
      if (!authHeader || !authHeader.startsWith('Bearer ')) {
        return new Response(
          JSON.stringify({ code: 401, error: 'Unauthorized: Missing or invalid Bearer token' }),
          {
            status: 401,
            headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
          }
        );
      }

      const token = authHeader.substring(7);
      const secret = env.JWT_SECRET || 'default-jwt-secret';
      const result = await verifyJWT(token, secret);

      if (!result.valid) {
        return new Response(
          JSON.stringify({ code: 401, error: `Unauthorized: ${result.error}` }),
          {
            status: 401,
            headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
          }
        );
      }
      validatedUser = result.payload;
    }

    // 3. 构建发往后端的代理请求头
    const proxyHeaders = new Headers(request.headers);
    if (validatedUser) {
      if (validatedUser.user_id) proxyHeaders.set('X-User-Id', validatedUser.user_id);
      if (validatedUser.tenant_id) proxyHeaders.set('X-Tenant-Id', validatedUser.tenant_id);
    }
    proxyHeaders.set('X-Forwarded-Host', url.host);
    proxyHeaders.set('X-Forwarded-Proto', url.protocol.replace(':', ''));

    // 4. 智能上游分发与实时故障转移 (GTM 调度效果)
    const primaryBase = env.PRIMARY_UPSTREAM || 'https://vps-api.svc.plus';
    const fallbackBase = env.FALLBACK_UPSTREAM || 'https://accounts-service-uc.a.run.app';
    const timeoutMs = parseInt(env.TIMEOUT_MS || '2500', 10);

    const primaryUrl = new URL(url.pathname + url.search, primaryBase);
    const fallbackUrl = new URL(url.pathname + url.search, fallbackBase);

    try {
      // 优先向主节点 (VPS) 发起请求 (带超时快速熔断)
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

      const primaryRes = await fetch(primaryUrl.toString(), {
        method: request.method,
        headers: proxyHeaders,
        body: request.body,
        signal: controller.signal,
      });
      clearTimeout(timeoutId);

      // 如果 VPS 节点健康返回 (< 500)，直接透传返回
      if (primaryRes.status < 500) {
        const responseHeaders = new Headers(primaryRes.headers);
        Object.entries(CORS_HEADERS).forEach(([k, v]) => responseHeaders.set(k, v));
        responseHeaders.set('X-Upstream-Route', 'vps-primary');
        return new Response(primaryRes.body, {
          status: primaryRes.status,
          headers: responseHeaders,
        });
      }

      throw new Error(`VPS upstream returned status ${primaryRes.status}`);
    } catch (err: any) {
      // 5. VPS 超时、网络异常或 5xx 故障时，秒级无缝降级至 GCP Cloud Run
      console.warn(`[Failover] Primary VPS failed (${err.message}). Routing to Cloud Run fallback.`);

      const fallbackRes = await fetch(fallbackUrl.toString(), {
        method: request.method,
        headers: proxyHeaders,
        body: request.body,
      });

      const responseHeaders = new Headers(fallbackRes.headers);
      Object.entries(CORS_HEADERS).forEach(([k, v]) => responseHeaders.set(k, v));
      responseHeaders.set('X-Upstream-Route', 'cloud-run-fallback');

      return new Response(fallbackRes.body, {
        status: fallbackRes.status,
        headers: responseHeaders,
      });
    }
  },
};
