#!/usr/bin/env bash
# Apply SOC2 change-management controls (CC8) to the default branch and turn on
# secret scanning + push protection (CC6). Settings live at the GitHub repo level,
# not in the codebase, so an org owner runs this once (and after any repo move):
#
#   ./.github/branch-protection.sh Kelsus/kelsus-oss-ai-ref-arch
#
# Requires: gh CLI authenticated as an org owner/admin.
set -euo pipefail

REPO="${1:?usage: branch-protection.sh <owner/repo> [branch]}"
BRANCH="${2:-main}"

echo "==> branch protection on ${REPO}@${BRANCH}"
# Status-check contexts are the job names in .github/workflows/ci.yml.
gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["terraform", "python-and-shell"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON

echo "==> secret scanning + push protection"
# Free on public repos; on private repos this requires GitHub Advanced Security.
# If your plan lacks GHAS this call 422s — enable GHAS or run it after going public.
gh api -X PATCH "repos/${REPO}" --input - <<'JSON' >/dev/null
{
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}
JSON

echo "done: ${REPO}@${BRANCH} protected; secret scanning + push protection on."
