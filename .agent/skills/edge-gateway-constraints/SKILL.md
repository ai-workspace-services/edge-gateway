---
name: edge-gateway-constraints
description: >-
  Enforces lightweight Cloudflare Worker engineering constraints and architectural rules
  for edge-gateway.svc.plus, covering zero-dependency runtime, Web Crypto API, CPU budgeting,
  in-flight GTM failover, Vault secrets sync, and Git/CI workflows.
---

# Edge Gateway Engineering Constraints & Guidelines

This skill defines the non-negotiable architectural rules, runtime constraints, and operational standards for developing and maintaining the **`edge-gateway.svc.plus`** Cloudflare Worker.

---

## 1. Zero-Dependency & Bundle Size Budget (零重型依赖与体积红线)

* **No Heavy NPM Packages**:
  * ❌ **FORBIDDEN**: Do NOT install heavy node libraries such as `jsonwebtoken`, `crypto-js`, `axios`, `express`, `lodash`, `moment`, or heavyweight ORMs.
  * ✅ **MANDATORY**: Use native V8 / Web Standard APIs:
    * `crypto.subtle` (Web Crypto API) for HMAC-SHA256, RSA verification, and cryptographic hashing.
    * Native `fetch`, `Request`, `Response`, `Headers`, and `URL`.
    * Native `TextEncoder` / `TextDecoder` and `atob` / `btoa` for Base64URL encoding/decoding.
* **Bundle Size Limit**:
  * The compiled Worker script MUST remain **strictly under 1 MB** (compressed) to guarantee zero-cost Free Plan compliance.

---

## 2. Compute Budget & CPU Time Limit (计算预算与 10ms CPU 红线)

* **Execution Time Ceiling**:
  * Free tier enforces a **10ms CPU time limit** per invocation (I/O wait time during `fetch()` does not count towards CPU time, but active JavaScript parsing and cryptography do).
* **No Heavy CPU Computation on Edge**:
  * ❌ Do NOT run heavy CPU tasks like high-cost `bcrypt` hashing, image transformations, or deep recursive AST transformations on the Worker.
  * ✅ Delegate CPU-intensive password generation and database mutations to the backend Go microservices.

---

## 3. GTM-Like Traffic Steering & Failover Contract (GTM 流量调度与容灾规范)

The Edge Gateway serves as an intelligent, zero-cost traffic router with the following non-negotiable contracts:

1. **CORS & OPTIONS Handling**:
   * All `OPTIONS` requests MUST be answered immediately at the edge with `204 No Content` and full CORS headers within **< 1ms**.
2. **Edge JWT Gatekeeping**:
   * Public routes in `PUBLIC_PATHS` (`/api/v1/auth/login`, `/healthz`, Stripe webhooks) bypass JWT verification.
   * Private `/api/*` endpoints MUST be verified at the edge using `verifyJWT()`. Invalid or expired tokens MUST be rejected with `HTTP 401` immediately before hitting upstream backends.
   * Verified user claims (`X-User-Id`, `X-Tenant-Id`) MUST be injected into upstream proxy headers.
3. **In-Flight Primary-Fallback Failover**:
   * Primary target: `PRIMARY_UPSTREAM` (VPS / Docker Compose).
   * Fallback target: `FALLBACK_UPSTREAM` (GCP Cloud Run - Scale-to-0).
   * Timeout: Primary request MUST enforce a strict timeout (`TIMEOUT_MS`, default `2500ms`).
   * Fallback Trigger: On network timeout, connection refusal, or `5xx` server error from the primary node, the Worker MUST transparently retry and return the response from the fallback node within the same request lifecycle.
   * Telemetry Headers: Must attach `X-Upstream-Route: selfhost-primary` or `X-Upstream-Route: cloud-run-fallback`.

---

## 4. Centralized Secrets Integration via `vault.svc.plus` (统一密钥管理)

* **Zero Plaintext Secrets**:
  * ❌ NEVER commit `.env`, API tokens, or JWT secrets into Git.
* **HashiCorp Vault SOT**:
  * All secrets originate from **`https://vault.svc.plus`** (Path: `secret/data/edge-gateway`).
  * In CI/CD: [`.github/scripts/deploy.sh`](file:///.github/scripts/deploy.sh) dynamically retrieves secrets via `VAULT_TOKEN` and passes them directly to `npx wrangler secret put`.
  * In Local Dev: Use [`scripts/fetch_secrets.sh`](file:///scripts/fetch_secrets.sh) to fetch secrets into `.env.local`.

---

## 5. CI/CD & Git Workflow Discipline

* **GitHub Actions Rule**:
  * Never write inline shell logic in `.github/workflows/*.yaml` `run:` blocks. All automation scripts must be standalone, executable files in `.github/scripts/*.sh`.
* **Branch Protection & PR Gate**:
  * Never commit or push directly to `main`.
  * Always branch from `main` using `feature/*` or `fix/*`, push to `origin`, and open a Pull Request via `gh pr create`.
