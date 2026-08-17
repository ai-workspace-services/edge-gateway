/** Shared lightweight proxy implementation for API boundary Workers. */

import { CORS_HEADERS, Env, GatewayBoundary, PUBLIC_PATHS, ownsPath } from './config';
import { verifyJWT } from './jwt';

function jsonResponse(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

function withRouteHeader(response: Response, route: string): Response {
  const headers = new Headers(response.headers);
  Object.entries(CORS_HEADERS).forEach(([key, value]) => headers.set(key, value));
  headers.set('X-Upstream-Route', route);
  return new Response(response.body, { status: response.status, headers });
}

export function createGatewayWorker(boundary: GatewayBoundary) {
  return {
    async fetch(request: Request, env: Env): Promise<Response> {
      const url = new URL(request.url);

      if (!ownsPath(url.pathname, boundary)) {
        return jsonResponse({ code: 404, error: `Unknown API boundary: ${boundary}` }, 404);
      }

      if (request.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: CORS_HEADERS });
      }

      const isPublic = PUBLIC_PATHS.some((path) => url.pathname.startsWith(path));
      let validatedUser: Record<string, any> | null = null;

      if (!isPublic) {
        const authHeader = request.headers.get('Authorization');
        if (!authHeader || !authHeader.startsWith('Bearer ')) {
          return jsonResponse(
            { code: 401, error: 'Unauthorized: Missing or invalid Bearer token' },
            401,
          );
        }

        const result = await verifyJWT(
          authHeader.substring(7),
          env.JWT_SECRET || 'default-jwt-secret',
        );
        if (!result.valid) {
          return jsonResponse({ code: 401, error: `Unauthorized: ${result.error}` }, 401);
        }
        validatedUser = result.payload || null;
      }

      const proxyHeaders = new Headers(request.headers);
      if (validatedUser) {
        if (validatedUser.user_id) proxyHeaders.set('X-User-Id', validatedUser.user_id);
        if (validatedUser.tenant_id) proxyHeaders.set('X-Tenant-Id', validatedUser.tenant_id);
      }
      proxyHeaders.set('X-Forwarded-Host', url.host);
      proxyHeaders.set('X-Forwarded-Proto', url.protocol.replace(':', ''));
      proxyHeaders.set('X-Edge-Boundary', boundary);

      const primaryBase = env.PRIMARY_UPSTREAM;
      const fallbackBase = env.FALLBACK_UPSTREAM;
      const runtimeMode = env.RUNTIME_MODE || 'hybrid';
      if (!primaryBase || !fallbackBase) {
        return jsonResponse({ code: 500, error: 'Gateway upstreams are not configured' }, 500);
      }
      const timeoutMs = Number.parseInt(env.TIMEOUT_MS || '2500', 10);
      const primaryUrl = new URL(url.pathname + url.search, primaryBase);
      const fallbackUrl = new URL(url.pathname + url.search, fallbackBase);

      if (runtimeMode === 'serverless') {
        const serverlessResponse = await fetch(fallbackUrl, {
          method: request.method,
          headers: proxyHeaders,
          body: request.body,
        });
        return withRouteHeader(serverlessResponse, 'cloud-run-serverless');
      }

      if (runtimeMode === 'vps') {
        const vpsResponse = await fetch(primaryUrl, {
          method: request.method,
          headers: proxyHeaders,
          body: request.body,
        });
        return withRouteHeader(vpsResponse, 'vps-primary');
      }

      try {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
        const primaryResponse = await fetch(primaryUrl, {
          method: request.method,
          headers: proxyHeaders,
          body: request.body,
          signal: controller.signal,
        });
        clearTimeout(timeoutId);

        if (primaryResponse.status < 500) {
          return withRouteHeader(primaryResponse, 'vps-primary');
        }
        throw new Error(`VPS upstream returned status ${primaryResponse.status}`);
      } catch (error) {
        console.warn(`[Failover:${boundary}] Primary upstream failed`, error);
        const fallbackResponse = await fetch(fallbackUrl, {
          method: request.method,
          headers: proxyHeaders,
          body: request.body,
        });
        return withRouteHeader(fallbackResponse, 'cloud-run-fallback');
      }
    },
  };
}
