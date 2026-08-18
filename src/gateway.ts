/** Shared lightweight proxy implementation for API boundary Workers. */

import {
  backendServiceForPath,
  CORS_HEADERS,
  Env,
  GatewayBoundary,
  isPublicPath,
  ownsBillingHostPath,
  ownsPath,
} from './config';
import { verifyJWT } from './jwt';

function isBillingHost(hostname: string, configuredHost?: string): boolean {
  return Boolean(configuredHost && hostname === configuredHost.trim().toLowerCase());
}

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

function requestInit(request: Request, headers: Headers, signal?: AbortSignal): RequestInit {
  const init: RequestInit = {
    method: request.method,
    headers,
    signal,
  };

  if (request.method !== 'GET' && request.method !== 'HEAD') {
    // Clone the original request for every attempt so a hybrid retry can
    // forward the same POST/PUT/PATCH body after a primary failure.
    init.body = request.clone().body;
  }

  return init;
}

function timeoutMsFromEnv(value?: string): number {
  const parsed = Number.parseInt(value || '2500', 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 2500;
}

export function createGatewayWorker(boundary: GatewayBoundary) {
  return {
    async fetch(request: Request, env: Env): Promise<Response> {
      const url = new URL(request.url);
      const billingHostRequest =
        boundary === 'core' && isBillingHost(url.hostname, env.BILLING_HOST);

      if (
        !ownsPath(url.pathname, boundary) &&
        !(billingHostRequest && ownsBillingHostPath(url.pathname))
      ) {
        return jsonResponse({ code: 404, error: `Unknown API boundary: ${boundary}` }, 404);
      }

      if (request.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: CORS_HEADERS });
      }

      const isPublic = isPublicPath(url.pathname);
      let validatedUser: Record<string, any> | null = null;

      if (!isPublic) {
        const authHeader = request.headers.get('Authorization');
        if (!authHeader || !authHeader.startsWith('Bearer ')) {
          return jsonResponse(
            { code: 401, error: 'Unauthorized: Missing or invalid Bearer token' },
            401,
          );
        }

        if (!env.JWT_SECRET) {
          return jsonResponse({ code: 500, error: 'Gateway JWT secret is not configured' }, 500);
        }

        const result = await verifyJWT(authHeader.substring(7), env.JWT_SECRET);
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
      if (!['selfhost', 'serverless', 'hybrid'].includes(runtimeMode)) {
        return jsonResponse({ code: 500, error: `Unsupported runtime mode: ${runtimeMode}` }, 500);
      }
      if (runtimeMode !== 'serverless' && !primaryBase) {
        return jsonResponse({ code: 500, error: 'Primary upstream is not configured' }, 500);
      }
      if (runtimeMode !== 'selfhost' && !fallbackBase) {
        return jsonResponse({ code: 500, error: 'Fallback upstream is not configured' }, 500);
      }

      const backendService = billingHostRequest
        ? 'billing'
        : backendServiceForPath(url.pathname);
      const contentBase = env.CONTENT_UPSTREAM || env.CMS_UPSTREAM;
      const billingBase = env.BILLING_UPSTREAM;
      const serviceFallbackBase =
        backendService === 'content'
          ? contentBase || fallbackBase
          : backendService === 'billing'
            ? billingBase || fallbackBase
            : fallbackBase;

      if (runtimeMode === 'serverless' && !serviceFallbackBase) {
        return jsonResponse(
          { code: 500, error: `${backendService} upstream is not configured` },
          500,
        );
      }

      const timeoutMs = timeoutMsFromEnv(env.TIMEOUT_MS);
      const primaryUrl = primaryBase ? new URL(url.pathname + url.search, primaryBase) : null;
      const fallbackUrl = serviceFallbackBase
        ? new URL(url.pathname + url.search, serviceFallbackBase)
        : null;

      // X-Service-Token is a server-to-server credential. Never trust a copy
      // supplied by a browser; inject the Vault-provided secret only for the
      // Git-backed content service.
      proxyHeaders.delete('X-Service-Token');
      if (backendService === 'content' && env.CONTENT_SERVICE_TOKEN) {
        proxyHeaders.set('X-Service-Token', env.CONTENT_SERVICE_TOKEN);
      }

      if (runtimeMode === 'serverless') {
        const serverlessResponse = await fetch(fallbackUrl!, requestInit(request, proxyHeaders));
        return withRouteHeader(serverlessResponse, 'cloud-run-serverless');
      }

      if (runtimeMode === 'selfhost') {
        const vpsResponse = await fetch(primaryUrl!, requestInit(request, proxyHeaders));
        return withRouteHeader(vpsResponse, 'selfhost-primary');
      }

      let timeoutId: ReturnType<typeof setTimeout> | undefined;
      try {
        const controller = new AbortController();
        timeoutId = setTimeout(() => controller.abort(), timeoutMs);
        const primaryResponse = await fetch(primaryUrl!, requestInit(request, proxyHeaders, controller.signal));

        if (primaryResponse.status < 500) {
          return withRouteHeader(primaryResponse, 'selfhost-primary');
        }
        throw new Error(`VPS upstream returned status ${primaryResponse.status}`);
      } catch (error) {
        console.warn(`[Failover:${boundary}] Primary upstream failed`, error);
        const fallbackResponse = await fetch(fallbackUrl!, requestInit(request, proxyHeaders));
        return withRouteHeader(fallbackResponse, 'cloud-run-fallback');
      } finally {
        if (timeoutId) clearTimeout(timeoutId);
      }
    },
  };
}
