# Repository Agent Guide

Default local skill references for this repository:

- Edge Gateway Engineering Constraints: [skills/edge-gateway-constraints/SKILL.md](./skills/edge-gateway-constraints/SKILL.md)

## Default Policy

For any modifications to `edge-gateway.svc.plus` (including routing rules, JWT handling, upstream proxies, dependencies, CI/CD workflows, or secrets management), always strictly follow the **`edge-gateway-constraints`** skill.

## Core Rules Summary

1. **Lightweight & Zero-Heavy-Dependencies**: Never install heavy Node.js libraries (`jsonwebtoken`, `axios`, `express`, etc.). Use Web Standard APIs (`crypto.subtle`, `fetch`). Keep compressed bundle < 1 MB.
2. **CPU Budget Limit**: Keep per-request CPU execution time under 10ms. No heavy compute on edge.
3. **In-Flight GTM Failover**: Always route `PRIMARY_UPSTREAM` (VPS) with 2500ms timeout -> transparently fallback to `FALLBACK_UPSTREAM` (Cloud Run) on error.
4. **Secrets via Vault**: All secrets MUST be synced dynamically from `https://vault.svc.plus` (`secret/data/edge-gateway`).
5. **Clean CI/CD**: All workflow automation logic must be encapsulated inside `.github/scripts/*.sh`.
