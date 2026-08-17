#!/usr/bin/env bash
set -euo pipefail

# Keep every executable Worker bundle strictly below 3 MiB.
MAX_BYTES=$((3 * 1024 * 1024))
BUNDLE_DIR="$(mktemp -d /tmp/edge-gateway-bundles.XXXXXX)"
trap 'rm -rf "${BUNDLE_DIR}"' EXIT

check_boundary() {
  local boundary="$1"
  local config="wrangler.${boundary}.toml"
  local output_dir="${BUNDLE_DIR}/${boundary}"
  local bundle="${output_dir}/${boundary}.js"

  mkdir -p "${output_dir}"
  npx wrangler deploy "src/workers/${boundary}.ts" \
    --config "${config}" \
    --dry-run \
    --minify \
    --outdir "${output_dir}" >/dev/null

  if [[ ! -f "${bundle}" ]]; then
    echo "[bundle-size] ${boundary}: bundled output not found at ${bundle}" >&2
    exit 1
  fi

  local size_bytes
  size_bytes="$(wc -c < "${bundle}" | tr -d '[:space:]')"
  if (( size_bytes >= MAX_BYTES )); then
    echo "[bundle-size] ${boundary}: ${size_bytes} bytes (limit: < ${MAX_BYTES})" >&2
    exit 1
  fi

  echo "[bundle-size] ${boundary}: ${size_bytes} bytes (< ${MAX_BYTES})"
}

for boundary in auth admin core; do
  check_boundary "${boundary}"
done
