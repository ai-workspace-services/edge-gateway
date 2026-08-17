#!/usr/bin/env bash
set -euo pipefail

BOUNDARY="${1:-}"
CLOUDFLARE_ENV="${CLOUDFLARE_ENV:-uat}"
CONFIG_FILE="${EDGE_GATEWAY_CONFIG_FILE:-config/edge-gateway-boundaries.json}"

case "${BOUNDARY}" in
  auth|admin|core) ;;
  *) echo "boundary must be auth, admin, or core" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
test -f "${CONFIG_FILE}" || { echo "edge-gateway config not found: ${CONFIG_FILE}" >&2; exit 2; }

environment_config=".environments[\"${CLOUDFLARE_ENV}\"]"
worker_name="$(jq -er "${environment_config}.boundaries[\"${BOUNDARY}\"].worker_name" "${CONFIG_FILE}")"
route_suffix="$(jq -er "${environment_config}.boundaries[\"${BOUNDARY}\"].route" "${CONFIG_FILE}")"
api_host="$(jq -er "${environment_config}.api_host" "${CONFIG_FILE}")"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are required" >&2
  exit 1
fi

deploy_args=(
  deploy "src/workers/${BOUNDARY}.ts"
  --name "${worker_name}"
  --route "${api_host}${route_suffix}"
  --compatibility-date "2026-08-17"
  --node-compat
)
while IFS=$'\t' read -r key value; do
  deploy_args+=(--var "${key}:${value}")
done < <(jq -r "${environment_config}.vars | to_entries[] | [.key, .value] | @tsv" "${CONFIG_FILE}")

echo "==> [Wrangler] Deploying ${worker_name} with route ${api_host}${route_suffix}..."
npx wrangler "${deploy_args[@]}"
