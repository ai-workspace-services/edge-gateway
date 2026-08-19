import { describe, expect, it } from 'vitest';
import { backendServiceForPath, isPublicPath, ownsPath } from '../src/config';

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
