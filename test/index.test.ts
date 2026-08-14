import { describe, it, expect } from 'vitest';
import { verifyJWT } from '../src/jwt';

describe('Edge Gateway JWT Verification Tests', () => {
  const secret = 'test-secret-key-1234567890123456';

  it('should reject malformed tokens', async () => {
    const res = await verifyJWT('invalid.token', secret);
    expect(res.valid).toBe(false);
    expect(res.error).toBe('Malformed token');
  });

  it('should reject invalid signatures', async () => {
    // Header: {"alg":"HS256","typ":"JWT"}, Payload: {"sub":"user123"}
    const fakeToken = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMTIzIn0.fakesignature';
    const res = await verifyJWT(fakeToken, secret);
    expect(res.valid).toBe(false);
  });
});
