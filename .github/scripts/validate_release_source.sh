#!/usr/bin/env bash
set -euo pipefail
[[ "${GITHUB_REPOSITORY:-}" == ai-workspace-services/edge-gateway ]] || exit 2
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || exit 2
gh api "repos/${GITHUB_REPOSITORY}/compare/${GITHUB_SHA}...main" --jq '.status' | rg -qx 'ahead|identical' || {
  echo 'Gateway deployment source must be reviewed and merged into main' >&2; exit 2;
}
if [[ "${DEPLOY_ENV:-}" == prod ]]; then
  gh api "repos/${GITHUB_REPOSITORY}/environments/production" --jq \
    '.protection_rules | any(.type == "required_reviewers" and (.reviewers | length) > 0)' | rg -qx true || {
      echo 'PROD gateway deployment requires a configured environment reviewer' >&2; exit 2;
    }
fi
echo 'Reviewed deployment source and environment protection verified'
