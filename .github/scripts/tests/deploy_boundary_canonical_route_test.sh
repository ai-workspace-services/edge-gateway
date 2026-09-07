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
      "accounts_aliases": ["accounts-cloudflare-uat.onwalk.net"],
      "edge_gateway": {
        "defaults": {"fallback_upstream": "https://accounts.run.app"},
        "boundaries": [
          {
            "id": "core",
            "worker_name": "edge-gateway-core-uat",
            "routes": ["/api/*"]
          },
          {
            "id": "auth",
            "worker_name": "edge-gateway-auth-uat",
            "routes": ["/api/auth/*", "/api/v1/auth/*"]
          },
          {
            "id": "admin",
            "worker_name": "edge-gateway-admin-uat",
            "routes": ["/api/admin/*"]
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

deploy() {
  PATH="${test_dir}/bin:${PATH}" \
  MOCK_WRANGLER_ARGS="${test_dir}/wrangler.args" \
  EDGE_GATEWAY_CONFIG_FILE="${test_dir}/routing.json" \
  CLOUDFLARE_API_TOKEN="test-token" \
  CLOUDFLARE_ACCOUNT_ID="account-1" \
  bash "${repo_root}/.github/scripts/deploy_boundary.sh" "$1" >/dev/null
}

deploy core
grep -Fq -- '--route accounts-serverless-uat.onwalk.net/api/*' "${test_dir}/wrangler.args"
grep -Fq -- '--route accounts-uat.onwalk.net/api/*' "${test_dir}/wrangler.args"
grep -Fq -- '--route accounts-cloudflare-uat.onwalk.net/api/*' "${test_dir}/wrangler.args"

# Every boundary needs its own route on the canonical host. Without it the
# canonical name resolves only Core's /api/*, and Core answers a path it does
# not own with "Unknown API boundary: core" -- which is how sign-in through
# accounts.svc.plus started returning 404.
deploy auth
grep -Fq -- '--route accounts-serverless-uat.onwalk.net/api/auth/*' "${test_dir}/wrangler.args"
grep -Fq -- '--route accounts-serverless-uat.onwalk.net/api/v1/auth/*' "${test_dir}/wrangler.args"
grep -Fq -- '--route accounts-uat.onwalk.net/api/auth/*' "${test_dir}/wrangler.args"
grep -Fq -- '--route accounts-uat.onwalk.net/api/v1/auth/*' "${test_dir}/wrangler.args"
grep -Fq -- '--route accounts-cloudflare-uat.onwalk.net/api/auth/*' "${test_dir}/wrangler.args"
grep -Fq -- '--route accounts-cloudflare-uat.onwalk.net/api/v1/auth/*' "${test_dir}/wrangler.args"

deploy admin
grep -Fq -- '--route accounts-serverless-uat.onwalk.net/api/admin/*' "${test_dir}/wrangler.args"
grep -Fq -- '--route accounts-uat.onwalk.net/api/admin/*' "${test_dir}/wrangler.args"
grep -Fq -- '--route accounts-cloudflare-uat.onwalk.net/api/admin/*' "${test_dir}/wrangler.args"

echo "deploy_boundary_canonical_route_test: PASS"
