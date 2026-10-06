#!/usr/bin/env bash
set -euo pipefail
: "${EDGE_GATEWAY_CONFIG_FILE:?rendered config required}"
[[ "$(jq -r '.metadata.cutover_required' "${EDGE_GATEWAY_CONFIG_FILE}")" == true ]] || exit 0
[[ "${CUTOVER_RUN_ID:-}" =~ ^[0-9]+$ ]] || { echo 'Changing the database writer requires a successful full business cutover receipt' >&2; exit 2; }
receipt_dir="$(mktemp -d)"
trap 'rm -rf "${receipt_dir}"' EXIT
repository=ai-workspace-infra/platform-ops-toolkit
gh api "repos/${repository}/actions/runs/${CUTOVER_RUN_ID}" >"${receipt_dir}/run.json"
jq -e '.conclusion == "success" and .event == "workflow_dispatch" and
  .path == ".github/workflows/environment-data-operations.yml" and
  (.head_branch == "main" or (.head_branch | test("^v[0-9]")))' "${receipt_dir}/run.json" >/dev/null || {
  echo 'Cutover receipt must come from the successful trusted data operations workflow' >&2; exit 2;
}
head_sha="$(jq -er '.head_sha' "${receipt_dir}/run.json")"
gh api "repos/${repository}/compare/${head_sha}...main" --jq '.status' | rg -qx 'ahead|identical' || {
  echo 'Cutover workflow commit must have been reviewed and merged into main' >&2; exit 2;
}
gh run download "${CUTOVER_RUN_ID}" --repo "${repository}" --name "gtm-cutover-${CUTOVER_RUN_ID}" --dir "${receipt_dir}/artifact"
python3 - "${receipt_dir}" "${EDGE_GATEWAY_CONFIG_FILE}" "${CUTOVER_RUN_ID}" <<'PY'
import datetime, json, pathlib, re, sys
root, config_path, run_id = sys.argv[1:]
root = pathlib.Path(root)
run = json.loads((root / 'run.json').read_text())
receipt = json.loads((root / 'artifact' / 'gtm-cutover.json').read_text())
config = json.loads(pathlib.Path(config_path).read_text())
def require(value, message):
    if not value: raise SystemExit(message)
require(receipt.get('schema') == 'edge-gateway-cutover/v1', 'Unsupported cutover receipt')
require(receipt.get('run_id') == run_id and receipt.get('workflow_sha') == run['head_sha'], 'Receipt run identity mismatch')
require(receipt.get('environment') == config['metadata']['environment'], 'Receipt environment mismatch')
verified_at = datetime.datetime.fromisoformat(receipt['verified_at'].replace('Z', '+00:00'))
age = (datetime.datetime.now(datetime.timezone.utc) - verified_at).total_seconds()
require(0 <= age <= 600, 'A fresh cutover verification within 10 minutes is required')
defaults = config['spec']['serverless']['edge_gateway']['defaults']
bindings = {key: defaults[key] for key in ('primary_upstream', 'fallback_upstream', 'billing_primary_upstream', 'billing_fallback_upstream')}
bindings['mode'] = config['spec']['runtime']['mode']
require(receipt.get('bindings') == bindings, 'Receipt does not authorize these exact upstreams and mode')
require(receipt.get('writers_quiesced') is True and receipt.get('single_writer') is True and
        receipt.get('latest_native_schema') is True, 'Writer fence and latest schema verification required')
tables = receipt.get('tables', [])
expected = set('account_billing_profiles account_policy_snapshots account_quota_states admin_settings agents audit_logs billing_ledger billing_plans billing_source_sync_state bridge_credentials email_blacklist homepage_video_settings identities node_health_snapshots nodes oauth_exchange_codes overlay_config_acks overlay_device_credentials overlay_devices overlay_enrollment_sessions overlay_invites overlay_networks overlay_nodes overlay_registrations overlay_signed_config_acks rbac_permissions rbac_role_permissions rbac_roles sandbox_bindings scheduler_decisions sessions stripe_webhook_events subscriptions task_namespaces task_runs task_session_events task_sessions tenant_domains tenant_memberships tenants traffic_minute_buckets traffic_stat_checkpoints users xworkmate_profiles account_lifecycle_events mfa_recovery_codes password_recovery_challenges finance_invoices finance_payments finance_refunds finance_operations finance_operation_events'.split())
require(len(tables) == len(expected) and {t['table'] for t in tables} == expected, 'Full business table verification required')
for table in tables:
    require(type(table['source_rows']) is int and type(table['target_rows']) is int and
            table['source_rows'] >= 0 and table['source_rows'] == table['target_rows'], 'Business row counts differ')
    require(re.fullmatch('[0-9a-f]{64}', table['source_email_bound_sha256']) and
            table['source_email_bound_sha256'] == table['target_email_bound_sha256'], 'Business values differ')
for key in ('email_set_sha256', 'email_proxy_sha256'):
    require(re.fullmatch('[0-9a-f]{64}', receipt['source'][key]) and
            receipt['source'][key] == receipt['target'][key], 'User emails or PROD Proxy UUIDs differ')
require(type(receipt['source']['users']) is int and type(receipt['target']['users']) is int and
        receipt['source']['users'] > 0 and receipt['source']['users'] == receipt['target']['users'], 'User counts differ')
print('Full business equality and single writer receipt accepted for the exact routing bindings')
PY
