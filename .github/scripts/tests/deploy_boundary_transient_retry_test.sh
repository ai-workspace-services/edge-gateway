#!/usr/bin/env bash
set -euo pipefail

# A Cloudflare 5xx during `wrangler deploy` used to fail the whole boundary job
# and, through it, every job gated on the Cloudflare lanes. The deploy is
# idempotent, so a transient upstream failure is retried -- but only a transient
# one, so that a real 4xx or config mistake still surfaces immediately.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rc=$?; rm -rf "${test_dir}"; exit ${rc}' EXIT

mkdir -p "${test_dir}/bin"
cat >"${test_dir}/routing.json" <<'EOF'
{
  "kind": "EdgeRoutingConfig",
  "metadata": {"mode": "serverless"},
  "spec": {
    "runtime": {"mode": "serverless", "routing": {"dns": {"canonical_records": {}}}},
    "serverless": {
      "accounts_host": "accounts-serverless-uat.onwalk.net",
      "edge_gateway": {
        "defaults": {"fallback_upstream": "https://accounts.run.app"},
        "boundaries": [
          {"id": "admin", "worker_name": "edge-gateway-admin-uat", "routes": ["/api/admin/*"]}
        ]
      }
    }
  }
}
EOF

# The stub records every invocation and fails the first FAIL_TIMES attempts with
# the message the failing mode is meant to describe.
cat >"${test_dir}/bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'call\n' >>"${MOCK_CALL_LOG}"
attempts="$(wc -l <"${MOCK_CALL_LOG}" | tr -d ' ')"
if (( attempts <= ${FAIL_TIMES:-0} )); then
  printf '%s\n' "${FAIL_MESSAGE}" >&2
  exit 1
fi
exit 0
EOF
chmod +x "${test_dir}/bin/npx"

deploy() {
  : >"${test_dir}/calls.log"
  PATH="${test_dir}/bin:${PATH}" \
  MOCK_CALL_LOG="${test_dir}/calls.log" \
  FAIL_TIMES="$1" \
  FAIL_MESSAGE="$2" \
  WRANGLER_RETRY_DELAY_SECONDS=0 \
  EDGE_GATEWAY_CONFIG_FILE="${test_dir}/routing.json" \
  CLOUDFLARE_API_TOKEN="test-token" \
  CLOUDFLARE_ACCOUNT_ID="account-1" \
  bash "${repo_root}/.github/scripts/deploy_boundary.sh" admin >/dev/null 2>&1
}

calls() { wc -l <"${test_dir}/calls.log" | tr -d ' '; }

transient='✘ [ERROR] Received a malformed response from the API
  upstream connect error or disconnect/reset before headers. reset reason: connection termination
  PATCH /accounts/x/workers/scripts/edge-gateway-admin-uat/script-settings -> 503 Service Unavailable'

# Two 503s then success: the deploy must recover rather than fail the rollout.
if ! deploy 2 "${transient}"; then
  echo "transient failure should have been retried to success" >&2
  exit 1
fi
if [[ "$(calls)" != "3" ]]; then
  echo "expected 3 wrangler attempts for a transient failure, got $(calls)" >&2
  exit 1
fi

# A non-transient failure must not be retried at all.
permanent='✘ [ERROR] A request to the Cloudflare API failed.
  Binding name "FOO" is invalid -> 400 Bad Request'
if deploy 99 "${permanent}"; then
  echo "a non-transient failure must not be reported as success" >&2
  exit 1
fi
if [[ "$(calls)" != "1" ]]; then
  echo "a non-transient failure must fail on the first attempt, got $(calls) attempts" >&2
  exit 1
fi

# The retry budget is bounded: a permanently transient API stops after the cap.
if deploy 99 "${transient}"; then
  echo "an unrecoverable transient failure must still fail" >&2
  exit 1
fi
if [[ "$(calls)" != "3" ]]; then
  echo "expected the retry budget to cap at 3 attempts, got $(calls)" >&2
  exit 1
fi

echo "deploy_boundary_transient_retry_test: PASS"
