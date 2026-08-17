import { describe, expect, it } from 'vitest';
import { ownsPath } from '../src/config';

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
});
