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
boundary_display_name="$(jq -er --arg boundary "${BOUNDARY}" '.spec.serverless.edge_gateway.boundaries[] | select(.id == $boundary) | (.display_name // .id)' "${CONFIG_FILE}")"
route_suffixes=()
while IFS= read -r route_suffix; do
  [[ -n "${route_suffix}" ]] || continue
  route_suffixes+=("${route_suffix}")
done < <(jq -er --arg boundary "${BOUNDARY}" '
  .spec.serverless.edge_gateway.boundaries[]
  | select(.id == $boundary)
  | (.routes // [.route])[]
' "${CONFIG_FILE}")
if [[ "${#route_suffixes[@]}" -eq 0 ]]; then
  echo "edge-gateway boundary ${BOUNDARY} must define at least one route" >&2
  exit 2
fi
api_host="$(jq -er '.spec.serverless.accounts_host' "${CONFIG_FILE}")"

# GitOps canonical aliases remain DNS CNAMEs to the mode-qualified host, so
# every Worker must also own its route on the canonical host: Cloudflare
# dispatches by the original Host header rather than chaining one Worker Custom
# Domain through another CNAME. Giving only Core the canonical route left
# accounts.svc.plus/api/auth/* and /api/admin/* dispatching to Core, which
# rejects paths it does not own with "Unknown API boundary: core" -- every
# sign-in against the canonical host failed with a 404. Each boundary claims
# its own suffixes here, so the more specific route still wins over Core's
# /api/* on the same host.
canonical_routes=()
while IFS=$'\t' read -r canonical_host canonical_target; do
  [[ -n "${canonical_host}" && "${canonical_target}" == "${api_host}" ]] || continue
  for route_suffix in "${route_suffixes[@]}"; do
    canonical_routes+=("${canonical_host}${route_suffix}")
  done
done < <(jq -r '.spec.runtime.routing.dns.canonical_records // {} | to_entries[] | [.key, .value] | @tsv' "${CONFIG_FILE}")
# Browser-facing Accounts aliases are Worker custom domains owned by the Core
# boundary. Add the same boundary-specific routes on each alias so /api/auth/*
# is dispatched to Auth instead of falling through to Core and returning
# "Unknown API boundary: core".
while IFS= read -r accounts_alias; do
  [[ -n "${accounts_alias}" ]] || continue
  for route_suffix in "${route_suffixes[@]}"; do
    canonical_routes+=("${accounts_alias}${route_suffix}")
  done
done < <(jq -r '.spec.serverless.accounts_aliases[]? // empty' "${CONFIG_FILE}")

vars_filter='(.spec.serverless.edge_gateway.defaults // {}) as $defaults | (.spec.serverless.cloud_run // {}) as $cloud_run | {RUNTIME_MODE: .spec.runtime.mode, PRIMARY_UPSTREAM: $defaults.primary_upstream, FALLBACK_UPSTREAM: $defaults.fallback_upstream, CONTENT_UPSTREAM: ($cloud_run.content_service // $defaults.content_upstream), BILLING_HOST: .spec.serverless.billing_host, BILLING_UPSTREAM: ($cloud_run.billing_service // $defaults.billing_upstream), JWT_ISSUER: $defaults.jwt_issuer, TIMEOUT_MS: $defaults.timeout_ms, FAILOVER_METHODS: ($defaults.failover_methods // [] | join(","))} | with_entries(select(.value != null and .value != ""))'

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are required" >&2
  exit 1
fi

deploy_args=(
  deploy "src/workers/${BOUNDARY}.ts"
  --name "${worker_name}"
  --compatibility-date "2026-08-17"
  --compatibility-flags "nodejs_compat"
)
for route_suffix in "${route_suffixes[@]}"; do
  deploy_args+=(--route "${api_host}${route_suffix}")
done
# Guarded: an environment that declares no canonical alias leaves this array
# empty, and older bash expands an empty array as unset under `set -u`.
if [[ "${#canonical_routes[@]}" -gt 0 ]]; then
  for route in "${canonical_routes[@]}"; do
    deploy_args+=(--route "${route}")
  done
fi
while IFS=$'\t' read -r key value; do
  deploy_args+=(--var "${key}:${value}")
done < <(jq -r "${vars_filter} | to_entries[] | [.key, .value] | @tsv" "${CONFIG_FILE}")

# Cloudflare's API intermittently answers a deploy from its own edge with a 5xx
# ("Received a malformed response from the API" / "upstream connect error"),
# after the bundle has already uploaded. `wrangler deploy` is idempotent, so the
# useful response to that is another attempt rather than a failed rollout that
# also blocks every downstream job.
#
# Only transient upstream markers are retried. A 4xx, a bad binding or a config
# mistake still fails on the first attempt: retrying those would turn a real
# break into a slow mystery instead of surfacing it.
WRANGLER_MAX_ATTEMPTS="${WRANGLER_MAX_ATTEMPTS:-3}"
WRANGLER_RETRY_DELAY_SECONDS="${WRANGLER_RETRY_DELAY_SECONDS:-5}"

is_transient_api_failure() {
  grep -qiE \
    'received a malformed response from the api|upstream connect error|reset before headers|-> 5[0-9]{2} |service unavailable|bad gateway|gateway timeout|fetch failed|ECONNRESET|ETIMEDOUT|socket hang up' \
    <<<"$1"
}

run_wrangler_with_retry() {
  local description="$1"
  shift
  local attempt=1
  local delay="${WRANGLER_RETRY_DELAY_SECONDS}"
  local output status

  while true; do
    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    printf '%s\n' "${output}"

    if [[ ${status} -eq 0 ]]; then
      return 0
    fi
    if (( attempt >= WRANGLER_MAX_ATTEMPTS )) || ! is_transient_api_failure "${output}"; then
      return "${status}"
    fi

    echo "==> [Wrangler] ${description} hit a transient Cloudflare API failure (attempt ${attempt}/${WRANGLER_MAX_ATTEMPTS}); retrying in ${delay}s..." >&2
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
  done
}

wrangler_deploy() {
  npx wrangler "$@"
}

wrangler_put_internal_service_token() {
  printf '%s' "${INTERNAL_SERVICE_TOKEN}" | npx wrangler secret put INTERNAL_SERVICE_TOKEN --name "$1"
}

echo "==> [Wrangler] Deploying ${boundary_display_name} (${worker_name}) with routes: ${route_suffixes[*]}..."
run_wrangler_with_retry "${boundary_display_name} deploy" wrangler_deploy "${deploy_args[@]}"

if [[ -n "${INTERNAL_SERVICE_TOKEN:-}" ]]; then
  echo "==> [Wrangler] Updating INTERNAL_SERVICE_TOKEN for ${BOUNDARY} Worker..."
  run_wrangler_with_retry "INTERNAL_SERVICE_TOKEN update" wrangler_put_internal_service_token "${worker_name}"
fi
