#!/usr/bin/env bash
set -euo pipefail
: "${EDGE_GATEWAY_CONFIG_FILE:?rendered config required}"
: "${CLOUDFLARE_API_TOKEN:?scoped provider token required}"
: "${CLOUDFLARE_ACCOUNT_ID:?provider account required}"

# A request to return to Serverless can also change the writer. Read actual
# deployed Worker bindings before publishing any secrets, routes or DNS.
python3 - <<'PY'
import json, os, pathlib, re, urllib.error, urllib.request
path = pathlib.Path(os.environ['EDGE_GATEWAY_CONFIG_FILE'])
config = json.loads(path.read_text())
desired = config['spec']['serverless']['edge_gateway']['defaults']
mode = config['spec']['runtime']['mode']
account = os.environ['CLOUDFLARE_ACCOUNT_ID']
if not re.fullmatch('[a-f0-9]{32}', account): raise SystemExit('Invalid scoped provider account')
writer_prefix = 'fallback' if mode == 'serverless' else 'primary'
expected = (desired[writer_prefix + '_upstream'], desired['billing_' + writer_prefix + '_upstream'])
changed = config['metadata'].get('cutover_required') is True
for boundary in config['spec']['serverless']['edge_gateway']['boundaries']:
    worker = boundary['worker_name']
    if not re.fullmatch('[a-z0-9][a-z0-9-]{0,62}', worker): raise SystemExit('Invalid Worker identity')
    request = urllib.request.Request(f'https://api.cloudflare.com/client/v4/accounts/{account}/workers/scripts/{worker}/settings',
        headers={'Authorization': 'Bearer ' + os.environ['CLOUDFLARE_API_TOKEN']})
    try:
        with urllib.request.urlopen(request, timeout=30) as response: data = json.load(response)
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise SystemExit('Cannot establish current writer; deployment stopped before mutations')
    if data.get('success') is not True: raise SystemExit('Cannot establish deployed Worker state')
    values = {b['name']: b.get('text') for b in data.get('result', {}).get('bindings', []) if b.get('type') == 'plain_text'}
    current = values.get('RUNTIME_MODE')
    if current not in ('serverless', 'selfhost', 'hybrid'):
        changed = True
        continue
    prefix = 'FALLBACK' if current == 'serverless' else 'PRIMARY'
    # Legacy gateway releases routed Billing directly to Cloud Run in every
    # mode; the absent dedicated Billing binding must not imply equality.
    billing = values.get('BILLING_' + prefix + '_UPSTREAM')
    if current == 'serverless': billing = billing or values.get('BILLING_UPSTREAM')
    actual = (values.get(prefix + '_UPSTREAM'), billing)
    if actual != expected: changed = True
config['metadata']['cutover_required'] = changed
path.write_text(json.dumps(config, indent=2) + '\n')
print('Current writer checked; full business receipt required=' + str(changed).lower())
PY
bash .github/scripts/verify_cutover.sh
