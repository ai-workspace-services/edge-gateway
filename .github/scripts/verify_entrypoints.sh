#!/usr/bin/env bash
set -euo pipefail
: "${EDGE_GATEWAY_CONFIG_FILE:?rendered routing config required}"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
api_host="$(jq -er '.spec.serverless.accounts_host' "${EDGE_GATEWAY_CONFIG_FILE}")"
billing_host="$(jq -er '.spec.serverless.billing_host' "${EDGE_GATEWAY_CONFIG_FILE}")"
mode="$(jq -er '.spec.runtime.mode' "${EDGE_GATEWAY_CONFIG_FILE}")"
check_entry() {
  local host="$1" path="$2" expected_status="$3" service="$4"
  local status route revision runtime
  status="$(curl --silent --show-error --max-time 30 --output /dev/null --dump-header "${work_dir}/headers" --write-out '%{http_code}' "https://${host}${path}")"
  [[ "${status}" =~ ${expected_status} ]] || { echo "${host}${path}: unexpected HTTP ${status}" >&2; exit 1; }
  route="$(awk 'tolower($1)=="x-upstream-route:" {gsub("\r", "", $2); print $2}' "${work_dir}/headers")"
  runtime="$(awk 'tolower($1)=="x-runtime-mode:" {gsub("\r", "", $2); print $2}' "${work_dir}/headers")"
  revision="$(awk 'tolower($1)=="x-gateway-revision:" {gsub("\r", "", $2); print $2}' "${work_dir}/headers")"
  [[ "${runtime}" == "${mode}" && "${revision}" == "${GATEWAY_REVISION:?expected revision required}" ]] || {
    echo "${host}: deployed runtime or revision mismatch" >&2; exit 1;
  }
  case "${mode}" in
    selfhost) [[ "${route}" == selfhost-primary ]] ;;
    serverless) [[ "${route}" == cloud-run-serverless || "${service}:${route}" == billing:cloud-run-billing ]] ;;
    hybrid) [[ "${route}" == selfhost-primary || "${route}" == cloud-run-fallback ]] ;;
  esac || { echo "${host}: unexpected upstream route ${route}" >&2; exit 1; }
  printf '%s%s HTTP %s mode=%s route=%s revision=%s\n' "${host}" "${path}" "${status}" "${runtime}" "${route}" "${revision}"
}
check_entry "${api_host}" /api/billing/plans '^200$' accounts
check_entry "${api_host}" /api/auth/mfa/status '^(200|400)$' accounts
check_entry "${billing_host}" /readyz '^200$' billing
while IFS=$'\t' read -r host target; do
  if [[ "${target}" == "${api_host}" ]]; then
    check_entry "${host}" /api/billing/plans '^200$' accounts
    check_entry "${host}" /api/auth/mfa/status '^(200|400)$' accounts
  elif [[ "${target}" == "${billing_host}" ]]; then
    check_entry "${host}" /readyz '^200$' billing
  fi
done < <(jq -r '.spec.runtime.routing.dns.canonical_records | to_entries[] | [.key,.value] | @tsv' "${EDGE_GATEWAY_CONFIG_FILE}")
