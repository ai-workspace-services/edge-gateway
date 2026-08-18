#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

mkdir -p "${test_dir}/bin"
cat >"${test_dir}/routing.json" <<'EOF'
{
  "kind": "EdgeRoutingConfig",
  "metadata": {"mode": "serverless"},
  "spec": {
    "runtime": {"mode": "serverless"},
    "serverless": {
      "accounts_host": "accounts-cloudflare-uat.onwalk.net",
      "cloud_run": {},
      "edge_gateway": {
        "defaults": {"fallback_upstream": "https://accounts.example.test"},
        "boundaries": [
          {
            "id": "auth",
            "worker_name": "edge-gateway-auth-uat",
            "routes": ["/api/auth/*", "/api/v1/auth/*"]
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
printf '%s\n' "$@" >"${MOCK_NPX_ARGS}"
EOF
chmod +x "${test_dir}/bin/npx"

pushd "${repo_root}" >/dev/null
PATH="${test_dir}/bin:${PATH}" \
MOCK_NPX_ARGS="${test_dir}/npx.args" \
CLOUDFLARE_API_TOKEN="test-token" \
CLOUDFLARE_ACCOUNT_ID="account-1" \
EDGE_GATEWAY_CONFIG_FILE="${test_dir}/routing.json" \
bash .github/scripts/deploy_boundary.sh auth >/dev/null
popd >/dev/null

grep -Fqx -- '--route' "${test_dir}/npx.args"
grep -Fqx -- 'accounts-cloudflare-uat.onwalk.net/api/auth/*' "${test_dir}/npx.args"
grep -Fqx -- 'accounts-cloudflare-uat.onwalk.net/api/v1/auth/*' "${test_dir}/npx.args"

echo "deploy_boundary_contract: PASS"
