/**
 * 路由白名单与网关配置
 */

export interface Env {
  RUNTIME_MODE?: 'selfhost' | 'serverless' | 'hybrid';
  PRIMARY_UPSTREAM?: string;
  FALLBACK_UPSTREAM?: string;
  JWT_ISSUER?: string;
  JWT_SECRET?: string;
  TIMEOUT_MS?: string;
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
  '/api/v1/health',
  '/healthz',
];

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
