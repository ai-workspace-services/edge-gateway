/**
 * 路由白名单与网关配置
 */

export type RuntimeMode = 'selfhost' | 'serverless' | 'hybrid';

export interface Env {
  RUNTIME_MODE?: RuntimeMode;
  PRIMARY_UPSTREAM?: string;
  FALLBACK_UPSTREAM?: string;
  CONTENT_UPSTREAM?: string;
  CMS_UPSTREAM?: string;
  BILLING_HOST?: string;
  BILLING_UPSTREAM?: string;
  CONTENT_SERVICE_TOKEN?: string;
  JWT_ISSUER?: string;
  JWT_SECRET?: string;
  TIMEOUT_MS?: string;
  FAILOVER_METHODS?: string;
}

// Hybrid failover crosses a database boundary: the selfhost primary writes to
// the VPS-managed PostgreSQL, the Cloud Run fallback writes to Supabase. Only
// methods that cannot mutate state may cross it, so a request the primary could
// not answer can never become a second write on the other side. A primary that
// times out mid-write is exactly the case this prevents from being replayed.
export const SAFE_FAILOVER_METHODS = ['GET', 'HEAD', 'OPTIONS'];

export function failoverMethodsFromEnv(value: string | undefined): string[] {
  if (!value) return SAFE_FAILOVER_METHODS;
  const declared = value
    .split(',')
    .map((method) => method.trim().toUpperCase())
    .filter(Boolean);
  if (declared.length === 0) return SAFE_FAILOVER_METHODS;
  return declared.filter((method) => SAFE_FAILOVER_METHODS.includes(method));
}

export type GatewayBoundary = 'auth' | 'admin' | 'core';

// 公开无需鉴权的路径前缀
export const PUBLIC_PATHS = [
  '/api/auth/login',
  '/api/auth/register',
  '/api/auth/verify-code',
  '/api/auth/refresh',
  '/api/auth/oauth',
  '/api/v1/auth/login',
  '/api/v1/auth/register',
  '/api/v1/auth/verify-code',
  '/api/v1/auth/refresh',
  '/api/v1/auth/oauth',
  '/api/v1/billing/stripe/webhook',
  '/api/v1/billing/plans',
  '/api/v1/blogs',
  '/api/v1/docs',
  '/api/v1/home',
  '/api/v1/products',
  '/api/v1/website',
  '/api/v1/health',
  '/healthz',
];

const CONTENT_API_PATHS = [
  '/api/v1/blogs',
  '/api/v1/docs',
  '/api/v1/home',
  '/api/v1/products',
  '/api/v1/website',
];

function matchesPath(pathname: string, prefix: string): boolean {
  return pathname === prefix || pathname.startsWith(`${prefix}/`);
}

export type BackendService = 'accounts' | 'content' | 'billing';

export function backendServiceForPath(pathname: string): BackendService {
  if (CONTENT_API_PATHS.some((path) => matchesPath(pathname, path))) {
    return 'content';
  }

  // Stripe webhooks are handled by accounts, even though they share the
  // billing URL family. Other billing APIs belong to billing-service.
  if (
    (matchesPath(pathname, '/api/billing') || matchesPath(pathname, '/api/v1/billing')) &&
    !matchesPath(pathname, '/api/billing/stripe/webhook') &&
    !matchesPath(pathname, '/api/v1/billing/stripe/webhook')
  ) {
    return 'billing';
  }

  return 'accounts';
}

export function isPublicPath(pathname: string): boolean {
  return PUBLIC_PATHS.some((path) => matchesPath(pathname, path));
}

export function ownsPath(pathname: string, boundary: GatewayBoundary): boolean {
  const authPath = pathname === '/api/auth' || pathname.startsWith('/api/auth/');
  const legacyAuthPath = pathname === '/api/v1/auth' || pathname.startsWith('/api/v1/auth/');
  const adminPath = pathname === '/api/admin' || pathname.startsWith('/api/admin/');

  if (boundary === 'auth') return authPath || legacyAuthPath;
  if (boundary === 'admin') return adminPath;
  return pathname.startsWith('/api/') && !authPath && !legacyAuthPath && !adminPath;
}

// 标准 CORS 响应头
export const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS, PATCH',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Requested-With, X-Tenant-Id, X-Workspace-Id',
  'Access-Control-Max-Age': '86400',
};
