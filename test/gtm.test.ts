import { afterEach, describe, expect, it, vi } from 'vitest';
import { createGatewayWorker } from '../src/gateway';
import type { Env } from '../src/config';

const env: Env = {
  PRIMARY_UPSTREAM: 'https://accounts-selfhost-prod.example.test',
  FALLBACK_UPSTREAM: 'https://accounts.run.example.test',
  BILLING_HOST: 'billing-serverless-prod.example.test',
  BILLING_ALIASES: 'billing.example.test',
  BILLING_PRIMARY_UPSTREAM: 'https://billing-selfhost-prod.example.test',
  BILLING_FALLBACK_UPSTREAM: 'https://billing.run.example.test',
  GATEWAY_REVISION: 'a'.repeat(40),
};
type FetchArgs = [input: Request | string | URL, init?: RequestInit];

describe('Accounts and Billing GTM', () => {
  afterEach(() => { vi.unstubAllGlobals(); });

  it.each(['billing.example.test', 'billing-serverless-prod.example.test'])(
    'serves the Billing canonical alias and qualified Serverless entry: %s', async (host) => {
      const upstream = vi.fn<FetchArgs, Promise<Response>>(async () => new Response('ready'));
      vi.stubGlobal('fetch', upstream);
      const response = await createGatewayWorker('core').fetch(new Request(`https://${host}/readyz`), { ...env, RUNTIME_MODE: 'serverless' });
      expect(String(upstream.mock.calls[0][0])).toBe('https://billing.run.example.test/readyz');
      expect(response.headers.get('X-Upstream-Route')).toBe('cloud-run-billing');
      expect(response.headers.get('X-Runtime-Mode')).toBe('serverless');
      expect(response.headers.get('X-Gateway-Revision')).toBe(env.GATEWAY_REVISION);
    },
  );

  it('switches Billing to its own Selfhost origin with Accounts', async () => {
    const upstream = vi.fn<FetchArgs, Promise<Response>>(async () => new Response('ready'));
    vi.stubGlobal('fetch', upstream);
    const response = await createGatewayWorker('core').fetch(new Request('https://billing.example.test/readyz'), { ...env, RUNTIME_MODE: 'selfhost' });
    expect(String(upstream.mock.calls[0][0])).toBe('https://billing-selfhost-prod.example.test/readyz');
    expect(response.headers.get('X-Upstream-Route')).toBe('selfhost-primary');
    expect(upstream).toHaveBeenCalledTimes(1);
  });

  it('fails Billing reads over to Billing Cloud Run in hybrid mode', async () => {
    const upstream = vi.fn<FetchArgs, Promise<Response>>()
      .mockResolvedValueOnce(new Response('unavailable', { status: 503 }))
      .mockResolvedValueOnce(new Response('ready'));
    vi.stubGlobal('fetch', upstream);
    const response = await createGatewayWorker('core').fetch(new Request('https://billing.example.test/readyz'), { ...env, RUNTIME_MODE: 'hybrid' });
    expect(String(upstream.mock.calls[0][0])).toBe('https://billing-selfhost-prod.example.test/readyz');
    expect(String(upstream.mock.calls[1][0])).toBe('https://billing.run.example.test/readyz');
    expect(response.headers.get('X-Upstream-Route')).toBe('cloud-run-fallback');
  });

  it('does not replay Billing writes across databases even with an unsafe override', async () => {
    const upstream = vi.fn<FetchArgs, Promise<Response>>(async () => new Response('unavailable', { status: 503 }));
    vi.stubGlobal('fetch', upstream);
    const response = await createGatewayWorker('core').fetch(new Request('https://billing.example.test/readyz', { method: 'POST' }), { ...env, RUNTIME_MODE: 'hybrid', FAILOVER_METHODS: 'POST,GET' });
    expect(response.status).toBe(503);
    expect(upstream).toHaveBeenCalledTimes(1);
  });

  it('keeps production Billing reads on the writer when the old database is not a qualified live replica', async () => {
    const upstream = vi.fn<FetchArgs, Promise<Response>>(async () => new Response('unavailable', { status: 503 }));
    vi.stubGlobal('fetch', upstream);
    const response = await createGatewayWorker('core').fetch(new Request('https://billing.example.test/readyz'), {
      ...env, RUNTIME_MODE: 'hybrid', BUSINESS_READ_FAILOVER: 'disabled',
    });
    expect(response.status).toBe(503);
    expect(upstream).toHaveBeenCalledTimes(1);
  });

  it('requires an explicit Billing Selfhost origin rather than sending it to Accounts', async () => {
    const upstream = vi.fn<FetchArgs, Promise<Response>>();
    vi.stubGlobal('fetch', upstream);
    const response = await createGatewayWorker('core').fetch(new Request('https://billing.example.test/readyz'), { ...env, RUNTIME_MODE: 'selfhost', BILLING_PRIMARY_UPSTREAM: undefined });
    expect(response.status).toBe(500);
    expect(upstream).not.toHaveBeenCalled();
  });

  it('answers Billing preflight at the edge without invoking either origin', async () => {
    const upstream = vi.fn<FetchArgs, Promise<Response>>();
    vi.stubGlobal('fetch', upstream);
    const response = await createGatewayWorker('core').fetch(new Request('https://billing.example.test/readyz', { method: 'OPTIONS' }), env);
    expect(response.status).toBe(204);
    expect(upstream).not.toHaveBeenCalled();
  });
});
