#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 本地从 vault.svc.plus 提取密钥并生成 .env.local
# -----------------------------------------------------------------------------

VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
VAULT_SECRETS_PATH="${VAULT_SECRETS_PATH:-secret/data/edge-gateway}"
OUTPUT_ENV_FILE="${1:-.env.local}"

echo "==> [Vault] Fetching edge-gateway secrets from ${VAULT_ADDR}..."

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "Error: Please set VAULT_TOKEN environment variable." >&2
  echo "Example: export VAULT_TOKEN=\"s.xxxxxxxxxxxxxx\"" >&2
  exit 1
fi

RESPONSE=$(curl -fsSL \
  --header "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/${VAULT_SECRETS_PATH}")

JWT_SECRET=$(echo "${RESPONSE}" | jq -r '.data.data.JWT_SECRET // .data.JWT_SECRET // empty')
PRIMARY_UPSTREAM=$(echo "${RESPONSE}" | jq -r '.data.data.PRIMARY_UPSTREAM // .data.PRIMARY_UPSTREAM // "https://vps-api.svc.plus"')
FALLBACK_UPSTREAM=$(echo "${RESPONSE}" | jq -r '.data.data.FALLBACK_UPSTREAM // .data.FALLBACK_UPSTREAM // "https://accounts-service-uc.a.run.app"')

cat <<EOF > "${OUTPUT_ENV_FILE}"
# Auto-generated from ${VAULT_ADDR} at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
PRIMARY_UPSTREAM=${PRIMARY_UPSTREAM}
FALLBACK_UPSTREAM=${FALLBACK_UPSTREAM}
TIMEOUT_MS=2500
JWT_SECRET=${JWT_SECRET}
EOF

echo "==> [Success] Generated ${OUTPUT_ENV_FILE} from Vault."
