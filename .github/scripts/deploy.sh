#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Edge Gateway 自动化部署脚本
# 密钥统一从 https://vault.svc.plus 动态拉取，零本地明文存储
# -----------------------------------------------------------------------------

VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
VAULT_SECRETS_PATH="${VAULT_SECRETS_PATH:-secret/data/edge-gateway}"
CONFIG_FILE="${EDGE_GATEWAY_CONFIG_FILE:?EDGE_GATEWAY_CONFIG_FILE must point to the rendered GitOps routing manifest}"

echo "==> [Vault] Fetching secrets from ${VAULT_ADDR} (${VAULT_SECRETS_PATH})..."

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "Error: VAULT_TOKEN is required to fetch secrets from ${VAULT_ADDR}" >&2
  exit 1
fi

# 从 Vault 获取密钥 JSON 数据
VAULT_RESPONSE=$(curl -fsSL \
  --header "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/${VAULT_SECRETS_PATH}" || true)

if [[ -z "${VAULT_RESPONSE}" ]]; then
  echo "Warning: Unable to fetch secrets from Vault or secret path is empty, checking fallback environment variables..."
else
  # 提取 JWT_SECRET
  JWT_SECRET=$(echo "${VAULT_RESPONSE}" | jq -r '.data.data.JWT_SECRET // .data.JWT_SECRET // empty')

  # 提取 CLOUDFLARE_API_TOKEN 与 CLOUDFLARE_ACCOUNT_ID (如果由 Vault 提供)
  CF_TOKEN=$(echo "${VAULT_RESPONSE}" | jq -r '.data.data.CLOUDFLARE_API_TOKEN // .data.CLOUDFLARE_API_TOKEN // empty')
  if [[ -n "${CF_TOKEN}" ]]; then
    export CLOUDFLARE_API_TOKEN="${CF_TOKEN}"
  fi

  CF_ACCOUNT=$(echo "${VAULT_RESPONSE}" | jq -r '.data.data.CLOUDFLARE_ACCOUNT_ID // .data.CLOUDFLARE_ACCOUNT_ID // empty')
  if [[ -n "${CF_ACCOUNT}" ]]; then
    export CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT}"
  fi
fi

echo "==> [Deploy] Deploying edge-gateway API boundary Workers..."
jq -e '.kind == "EdgeRoutingConfig" and .spec.mode == "serverless"' "${CONFIG_FILE}" >/dev/null || {
  echo "GitOps routing manifest must be an active serverless EdgeRoutingConfig" >&2
  exit 2
}
for boundary in auth admin core; do
  worker_name="$(jq -er --arg boundary "${boundary}" '.spec.serverless.edge_gateway.boundaries[] | select(.id == $boundary) | .worker_name' "${CONFIG_FILE}")"
  if [[ -n "${JWT_SECRET:-}" ]]; then
    echo "==> [Wrangler] Updating JWT_SECRET for ${boundary} Worker..."
    printf '%s' "${JWT_SECRET}" | npx wrangler secret put JWT_SECRET --name "${worker_name}"
  fi
  bash .github/scripts/deploy_boundary.sh "${boundary}"
done

echo "==> [Success] Edge Gateway deployment completed successfully."
