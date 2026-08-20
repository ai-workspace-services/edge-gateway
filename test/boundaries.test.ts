import { describe, expect, it } from 'vitest';
import {
  backendServiceForPath,
  hasSessionCredential,
  isPublicPath,
  looksLikeJWT,
  ownsPath,
} from '../src/config';

describe('API boundary ownership', () => {
  it('assigns auth and legacy auth routes to the auth Worker', () => {
    expect(ownsPath('/api/auth/login', 'auth')).toBe(true);
    expect(ownsPath('/api/v1/auth/refresh', 'auth')).toBe(true);
    expect(ownsPath('/api/admin/users', 'auth')).toBe(false);
  });

  it('assigns admin routes only to the admin Worker', () => {
    expect(ownsPath('/api/admin/users', 'admin')).toBe(true);
    expect(ownsPath('/api/auth/login', 'admin')).toBe(false);
  });

  it('keeps reserved auth and admin paths out of the core Worker', () => {
    expect(ownsPath('/api/account/profile', 'core')).toBe(true);
    expect(ownsPath('/api/auth/login', 'core')).toBe(false);
    expect(ownsPath('/api/admin/users', 'core')).toBe(false);
  });

  it('classifies Git-backed CMS and billing APIs for service routing', () => {
    expect(backendServiceForPath('/api/v1/products/xconnect')).toBe('content');
    expect(backendServiceForPath('/api/v1/docs/pages/guide/overview')).toBe('content');
    expect(backendServiceForPath('/api/v1/billing/plans')).toBe('billing');
    expect(backendServiceForPath('/api/v1/billing/stripe/webhook')).toBe('accounts');
  });

  it('allows SSR content reads through the gateway without a user JWT', () => {
    expect(isPublicPath('/api/v1/products/xconnect')).toBe(true);
    expect(isPublicPath('/api/v1/products-archive')).toBe(false);
  });

  it('allows the pre-authentication sign-in endpoints', () => {
    // The login screen reads the MFA status before any session exists; a 401
    // here leaves the verification-method selector permanently empty.
    expect(isPublicPath('/api/auth/mfa/status')).toBe(true);
    // The OAuth callback trades a code for a session, so it cannot present one.
    expect(isPublicPath('/api/auth/token/exchange')).toBe(true);
    expect(isPublicPath('/api/auth/verify-email')).toBe(true);
    expect(isPublicPath('/api/auth/verify-email/send')).toBe(true);
    expect(isPublicPath('/api/auth/register/send')).toBe(true);
    expect(isPublicPath('/api/v1/auth/mfa/status')).toBe(true);
    expect(isPublicPath('/api/v1/auth/token/exchange')).toBe(true);
  });

  it('keeps post-authentication endpoints behind the gateway', () => {
    // Enrolling and confirming a TOTP secret happen from an authenticated
    // session; only the status probe runs before sign-in.
    expect(isPublicPath('/api/auth/mfa/setup')).toBe(false);
    expect(isPublicPath('/api/auth/mfa/verify')).toBe(false);
    expect(isPublicPath('/api/auth/session')).toBe(false);
    expect(isPublicPath('/api/auth/subscriptions')).toBe(false);
    // Prefix matching must not leak a neighbouring path.
    expect(isPublicPath('/api/auth/mfa/status-report')).toBe(false);
    expect(isPublicPath('/api/auth/token/introspect')).toBe(false);
  });
});

describe('browser session credentials', () => {
  it('recognises the accounts session cookie among others', () => {
    expect(hasSessionCredential('theme=dark; xc_session=abc123; locale=zh')).toBe(true);
    expect(hasSessionCredential('xc_session=abc123')).toBe(true);
    // An empty or absent cookie is not a credential.
    expect(hasSessionCredential('xc_session=')).toBe(false);
    expect(hasSessionCredential('theme=dark')).toBe(false);
    expect(hasSessionCredential(null)).toBe(false);
    // A different cookie must not match on prefix.
    expect(hasSessionCredential('xc_session_backup=abc123')).toBe(false);
  });

  it('separates JWTs from the opaque session token accounts issues', () => {
    expect(looksLikeJWT('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1In0.sig')).toBe(true);
    expect(looksLikeJWT('7f3c1e9a4b8d2c6e5f0a1b2c3d4e5f60')).toBe(false);
    expect(looksLikeJWT('')).toBe(false);
  });
});
