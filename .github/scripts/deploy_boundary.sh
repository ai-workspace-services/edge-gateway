#!/usr/bin/env bash
set -euo pipefail

BOUNDARY="${1:-}"
CLOUDFLARE_ENV="${CLOUDFLARE_ENV:-uat}"
CONFIG_FILE="${EDGE_GATEWAY_CONFIG_FILE:?EDGE_GATEWAY_CONFIG_FILE must point to the rendered GitOps routing manifest}"

case "${BOUNDARY}" in
  auth|admin|core) ;;
  *) echo "boundary must be auth, admin, or core" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
test -f "${CONFIG_FILE}" || { echo "edge-gateway config not found: ${CONFIG_FILE}" >&2; exit 2; }

jq -e '.kind == "EdgeRoutingConfig" and (.spec.runtime.mode == "serverless" or .spec.runtime.mode == "hybrid")' "${CONFIG_FILE}" >/dev/null || {
  echo "GitOps routing manifest must be an active serverless or hybrid EdgeRoutingConfig" >&2
  exit 2
}
worker_name="$(jq -er --arg boundary "${BOUNDARY}" '.spec.serverless.edge_gateway.boundaries[] | select(.id == $boundary) | .worker_name' "${CONFIG_FILE}")"
route_suffix="$(jq -er --arg boundary "${BOUNDARY}" '.spec.serverless.edge_gateway.boundaries[] | select(.id == $boundary) | .route' "${CONFIG_FILE}")"
api_host="$(jq -er '.spec.serverless.accounts_host' "${CONFIG_FILE}")"
vars_filter='{RUNTIME_MODE: .spec.runtime.mode} + (.spec.serverless.edge_gateway.defaults | {PRIMARY_UPSTREAM: .primary_upstream, FALLBACK_UPSTREAM: .fallback_upstream, JWT_ISSUER: .jwt_issuer, TIMEOUT_MS: .timeout_ms})'

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are required" >&2
  exit 1
fi

deploy_args=(
  deploy "src/workers/${BOUNDARY}.ts"
  --name "${worker_name}"
  --route "${api_host}${route_suffix}"
  --compatibility-date "2026-08-17"
  --compatibility-flags "nodejs_compat"
)
while IFS=$'\t' read -r key value; do
  deploy_args+=(--var "${key}:${value}")
done < <(jq -r "${vars_filter} | to_entries[] | [.key, .value] | @tsv" "${CONFIG_FILE}")

echo "==> [Wrangler] Deploying ${worker_name} with route ${api_host}${route_suffix}..."
npx wrangler "${deploy_args[@]}"
