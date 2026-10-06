#!/usr/bin/env bash
set -euo pipefail
: "${EDGE_GATEWAY_CONFIG_FILE:?rendered config required}"

# Legacy orchestrators may deploy older contracts. The explicit PROD GTM
# contract has exactly one mutation entry, after its live writer check.
python3 - <<'PY'
import hashlib, json, os, pathlib, time
path = pathlib.Path(os.environ['EDGE_GATEWAY_CONFIG_FILE'])
config = json.loads(path.read_text())
guarded = (config['metadata'].get('environment') == 'prod' and
    config['spec']['runtime'].get('routing', {}).get('dns', {}).get('api_alias_mode') == 'worker-routes-cname')
if not guarded: raise SystemExit(0)
def require(value):
    if not value: raise SystemExit('PROD GTM publication requires the guarded Edge Gateway dispatch and live writer authorization')
require(os.environ.get('GITHUB_REPOSITORY') == 'ai-workspace-services/edge-gateway')
require(os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch')
require(os.environ.get('GITHUB_WORKFLOW_REF', '').startswith('ai-workspace-services/edge-gateway/.github/workflows/deploy.yml@'))
root = os.environ.get('RUNNER_TEMP')
require(root)
authorization = pathlib.Path(root) / 'edge-gateway-live-authorization.json'
require(authorization.is_file() and not authorization.is_symlink())
try: receipt = json.loads(authorization.read_text())
except (OSError, ValueError): require(False)
require(receipt.get('plan_sha256') == hashlib.sha256(path.read_bytes()).hexdigest())
require(receipt.get('revision') == os.environ.get('GATEWAY_REVISION') == os.environ.get('GITHUB_SHA'))
require(receipt.get('run_id') == os.environ.get('GITHUB_RUN_ID'))
require(receipt.get('run_attempt') == os.environ.get('GITHUB_RUN_ATTEMPT'))
timestamp = receipt.get('verified_at')
require(type(timestamp) in (float, int) and 0 <= time.time() - timestamp <= 600)
PY
