#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rc=$?; rm -rf "${test_dir}"; exit ${rc}' EXIT

mkdir -p "${test_dir}/bin"
cat >"${test_dir}/routing.json" <<'EOF'
{
  "kind": "EdgeRoutingConfig",
  "metadata": {"mode": "serverless"},
  "spec": {
    "runtime": {
      "mode": "serverless",
      "routing": {
        "dns": {
          "canonical_records": {
            "accounts-uat.onwalk.net": "accounts-serverless-uat.onwalk.net"
          }
        }
      }
    },
    "serverless": {
      "accounts_host": "accounts-serverless-uat.onwalk.net",
      "edge_gateway": {
        "defaults": {"fallback_upstream": "https://accounts.run.app"},
        "boundaries": [
          {
            "id": "core",
            "worker_name": "edge-gateway-core-uat",
            "routes": ["/api/*"]
          }
        ]
      }
    }
  }
}
EOF

cat >"${test_dir}/bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${MOCK_WRANGLER_ARGS}"
EOF
chmod +x "${test_dir}/bin/npx"

PATH="${test_dir}/bin:${PATH}" \
MOCK_WRANGLER_ARGS="${test_dir}/wrangler.args" \
EDGE_GATEWAY_CONFIG_FILE="${test_dir}/routing.json" \
CLOUDFLARE_API_TOKEN="test-token" \
CLOUDFLARE_ACCOUNT_ID="account-1" \
bash "${repo_root}/.github/scripts/deploy_boundary.sh" core >/dev/null

grep -Fq -- '--route accounts-serverless-uat.onwalk.net/api/*' "${test_dir}/wrangler.args"
grep -Fq -- '--route accounts-uat.onwalk.net/api/*' "${test_dir}/wrangler.args"
echo "deploy_boundary_canonical_route_test: PASS"
