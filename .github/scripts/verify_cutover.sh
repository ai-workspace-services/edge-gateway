#!/usr/bin/env bash
set -euo pipefail
: "${EDGE_GATEWAY_CONFIG_FILE:?rendered config required}"
[[ "$(jq -r '.metadata.cutover_required' "${EDGE_GATEWAY_CONFIG_FILE}")" == true ]] || exit 0
[[ "${CUTOVER_RUN_ID:-}" =~ ^[0-9]+$ ]] || { echo 'Changing the database writer requires a successful core-user cutover receipt' >&2; exit 2; }
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
require(receipt.get('schema') == 'edge-gateway-cutover/v2', 'Unsupported cutover receipt')
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
core = receipt.get('core_users')
require(isinstance(core, dict) and set(core) == {'source', 'target'}, 'Core user identity receipt missing')
for side in ('source', 'target'):
    proof = core[side]
    require(isinstance(proof, dict) and set(proof) ==
            {'count', 'email_sha256', 'password_hash_sha256', 'email_proxy_sha256'} and
            type(proof['count']) is int and proof['count'] > 0 and
            all(re.fullmatch('[0-9a-f]{64}', proof[key]) for key in
                ('email_sha256', 'password_hash_sha256', 'email_proxy_sha256')),
            'Core user identity digest is invalid')
require(core['source'] == core['target'], 'Core user email, password hash or Proxy UUID differs')
print('Core user identity equality and single writer receipt accepted for the exact routing bindings')
PY
