import { afterEach, describe, it, expect, vi } from 'vitest';
import { verifyJWT } from '../src/jwt';
import { createGatewayWorker } from '../src/gateway';

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

describe('runtime mode routing', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const request = new Request('https://accounts.example.test/api/auth/login');
  const baseEnv = {
    PRIMARY_UPSTREAM: 'https://vps.example.test',
    FALLBACK_UPSTREAM: 'https://cloud-run.example.test',
    TIMEOUT_MS: '2500',
  };
  type FetchArgs = [input: Request | string | URL, init?: RequestInit];

  it('routes selfhost mode to the VPS primary only', async () => {
    const fetchMock = vi.fn<FetchArgs, Promise<Response>>(async () => new Response('selfhost', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const response = await createGatewayWorker('auth').fetch(request, { ...baseEnv, RUNTIME_MODE: 'selfhost' });

    expect(response.headers.get('X-Upstream-Route')).toBe('selfhost-primary');
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(String(fetchMock.mock.calls[0][0])).toContain('vps.example.test');
  });

  it('routes serverless mode directly to Cloud Run', async () => {
    const fetchMock = vi.fn<FetchArgs, Promise<Response>>(async () => new Response('cloud-run', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const response = await createGatewayWorker('auth').fetch(request, { ...baseEnv, RUNTIME_MODE: 'serverless' });

    expect(response.headers.get('X-Upstream-Route')).toBe('cloud-run-serverless');
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(String(fetchMock.mock.calls[0][0])).toContain('cloud-run.example.test');
  });

  it('fails over from selfhost to Cloud Run only in hybrid mode', async () => {
    const fetchMock = vi
      .fn<FetchArgs, Promise<Response>>()
      .mockResolvedValueOnce(new Response('vps unavailable', { status: 503 }))
      .mockResolvedValueOnce(new Response('cloud-run fallback', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const response = await createGatewayWorker('auth').fetch(request, { ...baseEnv, RUNTIME_MODE: 'hybrid' });

    expect(response.headers.get('X-Upstream-Route')).toBe('cloud-run-fallback');
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(String(fetchMock.mock.calls[0][0])).toContain('vps.example.test');
    expect(String(fetchMock.mock.calls[1][0])).toContain('cloud-run.example.test');
  });
});
