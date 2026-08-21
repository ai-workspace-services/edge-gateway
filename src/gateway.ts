/** Shared lightweight proxy implementation for API boundary Workers. */

import {
  backendServiceForPath,
  CORS_HEADERS,
  Env,
  failoverMethodsFromEnv,
  GatewayBoundary,
  hasSessionCredential,
  isPublicPath,
  looksLikeJWT,
  ownsPath,
} from './config';
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
      const isBillingCustomDomain =
        boundary === 'core' && Boolean(env.BILLING_HOST) && url.hostname === env.BILLING_HOST;

      if (!isBillingCustomDomain && !ownsPath(url.pathname, boundary)) {
        return jsonResponse({ code: 404, error: `Unknown API boundary: ${boundary}` }, 404);
      }

      if (request.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: CORS_HEADERS });
      }

      const isPublic =
        isPublicPath(url.pathname) || (isBillingCustomDomain && url.pathname === '/readyz');
      const suppliedServiceToken = request.headers.get('X-Service-Token')?.trim();
      const isInternalServiceRequest =
        (url.pathname === '/api/internal' || url.pathname.startsWith('/api/internal/')) &&
        Boolean(env.INTERNAL_SERVICE_TOKEN) &&
        suppliedServiceToken === env.INTERNAL_SERVICE_TOKEN;
      let validatedUser: Record<string, any> | null = null;

      if (!isPublic && !isInternalServiceRequest) {
        const authHeader = request.headers.get('Authorization');
        const bearer = authHeader?.startsWith('Bearer ') ? authHeader.substring(7).trim() : '';
        // A browser has no JWT: accounts signs users in with an opaque session
        // token it stores server-side and hands back as a cookie, and it
        // validates that token itself on every route (Authorization, ?token=,
        // or the cookie). Rejecting those requests here made every signed-in
        // browser call -- starting with /api/auth/session right after login --
        // fail with "Missing or invalid Bearer token", regardless of whether
        // the session was valid. Pass the credential through to the service
        // that can actually resolve it; a forged one still gets a 401 there.
        const upstreamValidatesCredential =
          backendServiceForPath(url.pathname) === 'accounts' &&
          (hasSessionCredential(request.headers.get('Cookie')) || (bearer !== '' && !looksLikeJWT(bearer)));

        if (!upstreamValidatesCredential) {
          if (!bearer) {
            return jsonResponse(
              { code: 401, error: 'Unauthorized: Missing or invalid Bearer token' },
              401,
            );
          }

          if (!env.JWT_SECRET) {
            return jsonResponse({ code: 500, error: 'Gateway JWT secret is not configured' }, 500);
          }

          const result = await verifyJWT(bearer, env.JWT_SECRET);
          if (!result.valid) {
            return jsonResponse({ code: 401, error: `Unauthorized: ${result.error}` }, 401);
          }
          validatedUser = result.payload || null;
        }
      }

      const proxyHeaders = new Headers(request.headers);
      if (validatedUser) {
        if (validatedUser.user_id) proxyHeaders.set('X-User-Id', validatedUser.user_id);
        if (validatedUser.tenant_id) proxyHeaders.set('X-Tenant-Id', validatedUser.tenant_id);
      }
      proxyHeaders.set('X-Forwarded-Host', url.host);
      proxyHeaders.set('X-Forwarded-Proto', url.protocol.replace(':', ''));
      proxyHeaders.set('X-Edge-Boundary', boundary);

      if (isBillingCustomDomain) {
        if (!env.BILLING_UPSTREAM) {
          return jsonResponse({ code: 500, error: 'Billing upstream is not configured' }, 500);
        }
        const billingUrl = new URL(url.pathname + url.search, env.BILLING_UPSTREAM);
        const billingResponse = await fetch(billingUrl, requestInit(request, proxyHeaders));
        return withRouteHeader(billingResponse, 'cloud-run-billing');
      }

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

      const backendService = backendServiceForPath(url.pathname);
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
      if (isInternalServiceRequest && env.INTERNAL_SERVICE_TOKEN) {
        proxyHeaders.set('X-Service-Token', env.INTERNAL_SERVICE_TOKEN);
      } else if (backendService === 'content' && env.CONTENT_SERVICE_TOKEN) {
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

      const mayFailOver = failoverMethodsFromEnv(env.FAILOVER_METHODS).includes(
        request.method.toUpperCase(),
      );

      let timeoutId: ReturnType<typeof setTimeout> | undefined;
      try {
        const controller = new AbortController();
        timeoutId = setTimeout(() => controller.abort(), timeoutMs);
        const primaryResponse = await fetch(primaryUrl!, requestInit(request, proxyHeaders, controller.signal));

        if (primaryResponse.status < 500) {
          return withRouteHeader(primaryResponse, 'selfhost-primary');
        }
        if (!mayFailOver) {
          return withRouteHeader(primaryResponse, 'selfhost-primary');
        }
        throw new Error(`VPS upstream returned status ${primaryResponse.status}`);
      } catch (error) {
        if (!mayFailOver) {
          console.warn(`[Failover:${boundary}] Primary upstream failed for unsafe method ${request.method}; not retried`, error);
          return jsonResponse(
            { code: 502, error: `Primary upstream unavailable and ${request.method} may not fail over` },
            502,
          );
        }
        console.warn(`[Failover:${boundary}] Primary upstream failed`, error);
        const fallbackResponse = await fetch(fallbackUrl!, requestInit(request, proxyHeaders));
        return withRouteHeader(fallbackResponse, 'cloud-run-fallback');
      } finally {
        if (timeoutId) clearTimeout(timeoutId);
      }
    },
  };
}
