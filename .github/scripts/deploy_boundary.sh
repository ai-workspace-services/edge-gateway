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

jq -e '.kind == "EdgeRoutingConfig" and .metadata.mode == .spec.runtime.mode and (.spec.runtime.mode == "selfhost" or .spec.runtime.mode == "serverless" or .spec.runtime.mode == "hybrid")' "${CONFIG_FILE}" >/dev/null || {
  echo "GitOps routing manifest must be a valid mode-specific EdgeRoutingConfig" >&2
  exit 2
}
runtime_mode="$(jq -er '.spec.runtime.mode' "${CONFIG_FILE}")"
if [[ "${runtime_mode}" == "selfhost" ]]; then
  echo "==> [Deploy] Selfhost mode selected; boundary ${BOUNDARY} is intentionally not deployed."
  exit 0
fi
worker_name="$(jq -er --arg boundary "${BOUNDARY}" '.spec.serverless.edge_gateway.boundaries[] | select(.id == $boundary) | .worker_name' "${CONFIG_FILE}")"
route_suffix="$(jq -er --arg boundary "${BOUNDARY}" '.spec.serverless.edge_gateway.boundaries[] | select(.id == $boundary) | .route' "${CONFIG_FILE}")"
api_host="$(jq -er '.spec.serverless.accounts_host' "${CONFIG_FILE}")"
vars_filter='(.spec.serverless.edge_gateway.defaults // {}) as $defaults | (.spec.serverless.cloud_run // {}) as $cloud_run | {RUNTIME_MODE: .spec.runtime.mode, PRIMARY_UPSTREAM: $defaults.primary_upstream, FALLBACK_UPSTREAM: $defaults.fallback_upstream, CONTENT_UPSTREAM: ($cloud_run.content_service // $defaults.content_upstream), BILLING_UPSTREAM: ($cloud_run.billing_service // $defaults.billing_upstream), JWT_ISSUER: $defaults.jwt_issuer, TIMEOUT_MS: $defaults.timeout_ms} | with_entries(select(.value != null and .value != ""))'

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
