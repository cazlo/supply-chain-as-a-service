#!/usr/bin/env bash
set -euo pipefail

# Vendored-upstream sync driver, intended to run on a schedule as the machine
# identity (the supply-chain-sync bot). For every upstream in vendor/upstreams.tsv
# it imports any fast-forward commits with ci/subtree-sync.sh (the same machinery
# ci/check-vendored-upstreams.sh validates), collects them onto one rolling
# branch, and opens or updates a single pull request against the base branch.
#
# The resulting PR is deliberately NOT auto-deployable: publish-ci recognizes the
# bot author and runs validate-only (no Harbor push, sign, scan, or deploy). A
# human must review and merge, after which publishing happens through a manual
# approval step. See the plan's "Gitea Actions and builder design" section.
#
# Divergent (non-fast-forward) upstreams are reported and skipped; a human runs
# ci/subtree-sync.sh update by hand for those.
#
# Environment:
#   GITEA_SERVER   base URL, e.g. http://gitea-http.gitea.svc.cluster.local:3000
#   GITEA_TOKEN    bot token with write:repository on GITEA_REPO
#   GITEA_REPO     owner/name (default drew/supply-chain-as-a-service)
#   BASE_BRANCH    PR base (default main)
#   SYNC_BRANCH    rolling head branch (default automation/vendor-sync)
#   DRY_RUN        set to 1 to import locally without pushing or opening a PR

readonly root="$(git rev-parse --show-toplevel)"
readonly metadata="${root}/vendor/upstreams.tsv"
readonly server="${GITEA_SERVER:?GITEA_SERVER is required}"
readonly token="${GITEA_TOKEN:?GITEA_TOKEN is required}"
readonly repo="${GITEA_REPO:-drew/supply-chain-as-a-service}"
readonly base_branch="${BASE_BRANCH:-main}"
readonly sync_branch="${SYNC_BRANCH:-automation/vendor-sync}"
readonly api="${server%/}/api/v1"

log() { printf '==> %s\n' "$*" >&2; }

# curl wrapper for the Gitea API: $1 method, $2 path, optional $3 JSON body.
# Echoes "<body>\n<http_code>". The token is sent only as a header.
gitea() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "${body}" ]]; then
    curl -sS -X "${method}" -H "Authorization: token ${token}" \
      -H 'Content-Type: application/json' -d "${body}" \
      -w '\n%{http_code}' "${api}${path}"
  else
    curl -sS -X "${method}" -H "Authorization: token ${token}" \
      -w '\n%{http_code}' "${api}${path}"
  fi
}

upstream_names() { awk -F '\t' 'NR > 1 && NF { print $1 }' "${metadata}"; }
field() { awk -F '\t' -v name="$1" -v col="$2" '$1 == name { print $col; exit }' "${metadata}"; }

cd "${root}"
git config --get user.email >/dev/null || { echo "git user identity is not configured" >&2; exit 2; }

log "starting from ${base_branch}"
git fetch --quiet origin "${base_branch}"
git checkout -B "${sync_branch}" "origin/${base_branch}"

updated=()   # "name old->new"
diverged=()  # "name reason"

for name in $(upstream_names); do
  branch="$(field "${name}" 4)"      # default branch
  before_rev="$(field "${name}" 5)"  # recorded revision
  before_head="$(git rev-parse HEAD)"
  log "checking ${name} (${branch})"
  if out="$(ci/subtree-sync.sh update "${name}" "${branch}" 2>&1)"; then
    after_head="$(git rev-parse HEAD)"
    if [[ "${after_head}" != "${before_head}" ]]; then
      after_rev="$(field "${name}" 5)"
      updated+=("${name} ${before_rev:0:12}->${after_rev:0:12}")
      log "${name}: imported ${before_rev:0:12} -> ${after_rev:0:12}"
    else
      log "${name}: already current"
    fi
  else
    diverged+=("${name}: $(printf '%s' "${out}" | tail -n1)")
    log "${name}: skipped (non-fast-forward or error)"
  fi
done

if (( ${#updated[@]} == 0 )); then
  log "no upstream updates available"
  printf 'no-updates\n'
  exit 0
fi

# Build the PR body.
body_file="$(mktemp)"
trap 'rm -f "${body_file}"' EXIT
{
  echo "Automated vendored-upstream sync opened by the supply-chain-sync bot."
  echo
  echo "## Imported"
  for entry in "${updated[@]}"; do echo "- \`${entry}\`"; done
  if (( ${#diverged[@]} > 0 )); then
    echo
    echo "## Skipped (needs manual review)"
    for entry in "${diverged[@]}"; do echo "- ${entry}"; done
  fi
  echo
  echo "## Do not deploy without review"
  echo
  echo "publish-ci runs **validate-only** on this bot-authored PR: no image is"
  echo "pushed, signed, scanned, or deployed. Review the imported source, then"
  echo "merge. Publishing is a separate, manual approval step; the seven-day age"
  echo "policy still applies at deploy time."
} >"${body_file}"

if [[ "${DRY_RUN:-0}" == "1" || "${DRY_RUN:-}" == "true" ]]; then
  log "DRY_RUN: not pushing or opening a PR"
  cat "${body_file}"
  exit 0
fi

# Push the rolling branch over HTTPS with the bot token (auth never printed).
log "pushing ${sync_branch}"
push_url="${server%/}/${repo}.git"
push_url="${push_url/:\/\//://oauth2:${token}@}"
git push --force "${push_url}" "HEAD:refs/heads/${sync_branch}"

# Open a PR if one is not already open for this head; otherwise the force-push
# above already refreshed the existing PR.
existing="$(gitea GET "/repos/${repo}/pulls?state=open&type=pulls")"
existing_code="$(tail -n1 <<<"${existing}")"
[[ "${existing_code}" == 200 ]] || { echo "failed to list PRs (HTTP ${existing_code})" >&2; exit 1; }
open_number="$(sed '$d' <<<"${existing}" |
  jq -r --arg head "${sync_branch}" '.[] | select(.head.ref == $head) | .number' | head -n1)"

title="chore(vendor): sync $(date -u +%F) (${#updated[@]} upstream$( ((${#updated[@]}>1)) && echo s ))"
if [[ -n "${open_number}" ]]; then
  log "refreshed existing PR #${open_number}"
  body="$(jq -Rs . <"${body_file}")"
  gitea PATCH "/repos/${repo}/pulls/${open_number}" \
    "$(jq -nc --arg t "${title}" --argjson b "${body}" '{title:$t, body:$b}')" >/dev/null
  printf 'updated-pr %s\n' "${open_number}"
else
  payload="$(jq -nc \
    --arg title "${title}" \
    --rawfile body "${body_file}" \
    --arg head "${sync_branch}" \
    --arg base "${base_branch}" \
    '{title:$title, body:$body, head:$head, base:$base}')"
  resp="$(gitea POST "/repos/${repo}/pulls" "${payload}")"
  code="$(tail -n1 <<<"${resp}")"
  [[ "${code}" =~ ^20 ]] || { echo "failed to open PR (HTTP ${code}): $(sed '$d' <<<"${resp}")" >&2; exit 1; }
  number="$(sed '$d' <<<"${resp}" | jq -r '.number')"
  log "opened PR #${number}"
  printf 'opened-pr %s\n' "${number}"
fi
