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
    CONTENT_UPSTREAM: 'https://content-service.example.test',
    BILLING_HOST: 'billing-serverless.example.test',
    BILLING_UPSTREAM: 'https://billing-service.example.test',
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

  it('routes public Git-backed CMS reads to content-service with its service token', async () => {
    const fetchMock = vi.fn<FetchArgs, Promise<Response>>(async (_input, init) => {
      expect(new Headers(init?.headers).get('X-Service-Token')).toBe('content-token');
      return new Response('content', { status: 200 });
    });
    vi.stubGlobal('fetch', fetchMock);

    const response = await createGatewayWorker('core').fetch(
      new Request('https://accounts.example.test/api/v1/products/xconnect'),
      { ...baseEnv, RUNTIME_MODE: 'serverless', CONTENT_SERVICE_TOKEN: 'content-token' },
    );

    expect(response.headers.get('X-Upstream-Route')).toBe('cloud-run-serverless');
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(String(fetchMock.mock.calls[0][0])).toContain('content-service.example.test');
  });

  it('routes billing APIs to billing-service in serverless mode', async () => {
    const fetchMock = vi.fn<FetchArgs, Promise<Response>>(async () => new Response('billing', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const response = await createGatewayWorker('core').fetch(
      new Request('https://accounts.example.test/api/v1/billing/plans'),
      { ...baseEnv, RUNTIME_MODE: 'serverless' },
    );

    expect(response.headers.get('X-Upstream-Route')).toBe('cloud-run-serverless');
    expect(String(fetchMock.mock.calls[0][0])).toContain('billing-service.example.test');
  });

  it('proxies the Billing custom domain to billing-service without an Origin Rule', async () => {
    const fetchMock = vi.fn<FetchArgs, Promise<Response>>(async () => new Response('ready', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const response = await createGatewayWorker('core').fetch(
      new Request('https://billing-serverless.example.test/readyz'),
      { ...baseEnv, RUNTIME_MODE: 'serverless' },
    );

    expect(response.status).toBe(200);
    expect(response.headers.get('X-Upstream-Route')).toBe('cloud-run-billing');
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(String(fetchMock.mock.calls[0][0])).toBe('https://billing-service.example.test/readyz');
  });

  it('uses content-service as the hybrid fallback for CMS reads', async () => {
    const fetchMock = vi
      .fn<FetchArgs, Promise<Response>>()
      .mockResolvedValueOnce(new Response('selfhost unavailable', { status: 503 }))
      .mockResolvedValueOnce(new Response('content fallback', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const response = await createGatewayWorker('core').fetch(
      new Request('https://accounts.example.test/api/v1/blogs/hello'),
      { ...baseEnv, RUNTIME_MODE: 'hybrid', CONTENT_SERVICE_TOKEN: 'content-token' },
    );

    expect(response.headers.get('X-Upstream-Route')).toBe('cloud-run-fallback');
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(String(fetchMock.mock.calls[0][0])).toContain('vps.example.test');
    expect(String(fetchMock.mock.calls[1][0])).toContain('content-service.example.test');
  });

  it('does not require a fallback upstream when a selfhost gateway is exercised', async () => {
    const fetchMock = vi.fn<FetchArgs, Promise<Response>>(async () => new Response('selfhost', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);

    const response = await createGatewayWorker('auth').fetch(request, {
      PRIMARY_UPSTREAM: 'https://vps.example.test',
      RUNTIME_MODE: 'selfhost',
    });

    expect(response.status).toBe(200);
    expect(response.headers.get('X-Upstream-Route')).toBe('selfhost-primary');
  });
});
