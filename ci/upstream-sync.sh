#!/usr/bin/env bash
set -euo pipefail

# Vendored-upstream sync driver, intended to run on a schedule as the machine
# identity (the supply-chain-sync bot). For every upstream in vendor/upstreams.tsv
# it discovers the latest upstream *release* (not branch HEAD), holds it under a
# seven-day quarantine, and only once the release is old enough imports it with
# ci/subtree-sync.sh (the same machinery ci/check-vendored-upstreams.sh
# validates), collecting the signed commits onto one rolling branch and opening
# or updating a single pull request against the base branch.
#
# Why releases + quarantine, not branch HEAD: we vendor reviewed, tagged releases,
# and we apply the same seven-day software-age discipline to ourselves that the
# Artifact Keeper instance applies to proxied packages. A freshly cut release is
# held until it has existed for QUARANTINE_DAYS so a bad release has time to be
# yanked/superseded before we build and ship it.
#
# The resulting PR is deliberately NOT auto-deployable: publish-ci recognizes the
# bot author and runs validate-only (no Harbor push, sign, scan, or deploy). A
# human must review and merge, after which publishing happens through a manual
# approval step. See the plan's "Gitea Actions and builder design" section.
#
# Divergent (non-fast-forward) releases are reported and skipped; a human runs
# ci/subtree-sync.sh update by hand for those.
#
# Environment:
#   GITEA_SERVER     base URL, e.g. http://gitea-http.gitea.svc.cluster.local:3000
#   GITEA_TOKEN      bot token with write:repository on GITEA_REPO
#   GITEA_REPO       owner/name (default drew/supply-chain-as-a-service)
#   BASE_BRANCH      PR base (default main)
#   SYNC_BRANCH      rolling head branch (default automation/vendor-sync)
#   QUARANTINE       "true" (default): hold a release until it is QUARANTINE_DAYS
#                    old. Set "false" to import the latest release immediately.
#   QUARANTINE_DAYS  age threshold in days (default 7)
#   GITHUB_API       release-metadata API base (default https://api.github.com)
#   GITHUB_TOKEN     optional; raises the unauthenticated rate limit
#   DRY_RUN          set to 1 to import locally without pushing or opening a PR

readonly root="$(git rev-parse --show-toplevel)"
readonly metadata="${root}/vendor/upstreams.tsv"
readonly server="${GITEA_SERVER:?GITEA_SERVER is required}"
readonly token="${GITEA_TOKEN:?GITEA_TOKEN is required}"
readonly repo="${GITEA_REPO:-drew/supply-chain-as-a-service}"
readonly base_branch="${BASE_BRANCH:-main}"
readonly sync_branch="${SYNC_BRANCH:-automation/vendor-sync}"
readonly api="${server%/}/api/v1"
readonly github_api="${GITHUB_API:-https://api.github.com}"
readonly quarantine_days="${QUARANTINE_DAYS:-7}"

# Quarantine is on unless explicitly disabled. Scheduled (cron) runs pass no
# input, so an unset/empty value keeps the seven-day hold; only an explicit
# falsey value (the operator-flipped override) disables it.
quarantine_enabled=1
case "${QUARANTINE:-true}" in
  false | False | FALSE | 0 | no | No | off | Off) quarantine_enabled=0 ;;
esac

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

# curl wrapper for the GitHub release API. Echoes "<body>\n<http_code>".
github() {
  local path="$1"
  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl -sS "${auth[@]}" -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -w '\n%{http_code}' "${github_api%/}${path}"
}

upstream_names() { awk -F '\t' 'NR > 1 && NF { print $1 }' "${metadata}"; }
field() { awk -F '\t' -v name="$1" -v col="$2" '$1 == name { print $col; exit }' "${metadata}"; }

# https://github.com/owner/repo.git -> owner/repo
owner_repo_from_url() {
  local url="$1"
  url="${url#https://github.com/}"
  printf '%s' "${url%.git}"
}

cd "${root}"
git config --get user.email >/dev/null || { echo "git user identity is not configured" >&2; exit 2; }

if (( quarantine_enabled )); then
  log "quarantine ON: importing only releases at least ${quarantine_days} day(s) old"
else
  log "quarantine OFF: importing the latest release immediately (override)"
fi

log "starting from ${base_branch}"
git fetch --quiet origin "${base_branch}"
git checkout -B "${sync_branch}" "origin/${base_branch}"

now_epoch="$(date -u +%s)"

updated=()      # "name old_tag->new_tag (Nd old)"
quarantined=()  # "name tag: released Nd ago, eligible <date>"
diverged=()     # "name: reason"

for name in $(upstream_names); do
  url="$(field "${name}" 3)"
  current_tag="$(field "${name}" 6)"
  owner_repo="$(owner_repo_from_url "${url}")"
  log "checking ${name} (${owner_repo}) latest release"

  resp="$(github "/repos/${owner_repo}/releases/latest")"
  code="$(tail -n1 <<<"${resp}")"
  payload="$(sed '$d' <<<"${resp}")"
  if [[ "${code}" != 200 ]]; then
    diverged+=("${name}: no published release (HTTP ${code})")
    log "${name}: no published release (HTTP ${code})"
    continue
  fi

  release_tag="$(jq -r '.tag_name // empty' <<<"${payload}")"
  published_epoch="$(jq -r '(.published_at // empty) | if . == "" then empty else fromdateiso8601 end' <<<"${payload}")"
  if [[ -z "${release_tag}" || -z "${published_epoch}" ]]; then
    diverged+=("${name}: release metadata missing tag_name/published_at")
    log "${name}: release metadata missing tag_name/published_at"
    continue
  fi

  age_days=$(( (now_epoch - published_epoch) / 86400 ))

  if [[ "${release_tag}" == "${current_tag}" ]]; then
    log "${name}: already at release ${release_tag}"
    continue
  fi

  if (( quarantine_enabled && age_days < quarantine_days )); then
    eligible="$(date -u -d "@$(( published_epoch + quarantine_days * 86400 ))" +%F 2>/dev/null \
      || date -u -r "$(( published_epoch + quarantine_days * 86400 ))" +%F)"
    quarantined+=("${name} ${release_tag}: released ${age_days}d ago, eligible ${eligible}")
    log "${name}: ${release_tag} quarantined (${age_days}d < ${quarantine_days}d), eligible ${eligible}"
    continue
  fi

  before_head="$(git rev-parse HEAD)"
  if out="$(ci/subtree-sync.sh update "${name}" "${release_tag}" "${release_tag}" 2>&1)"; then
    after_head="$(git rev-parse HEAD)"
    if [[ "${after_head}" != "${before_head}" ]]; then
      updated+=("${name} ${current_tag}->${release_tag} (${age_days}d old)")
      log "${name}: imported ${current_tag} -> ${release_tag} (${age_days}d old)"
    else
      log "${name}: already current (${out##*$'\n'})"
    fi
  else
    diverged+=("${name} ${release_tag}: $(printf '%s' "${out}" | tail -n1)")
    log "${name}: failed to import ${release_tag}"
    printf '%s\n' "${out}" | sed 's/^/    /' >&2
  fi
done

if (( ${#updated[@]} == 0 )); then
  log "no upstream release updates to import"
  (( ${#quarantined[@]} > 0 )) && printf 'quarantined %s\n' "${#quarantined[@]}"
  printf 'no-updates\n'
  exit 0
fi

# Build the PR body.
body_file="$(mktemp)"
trap 'rm -f "${body_file}"' EXIT
{
  echo "Automated vendored-upstream release sync opened by the supply-chain-sync bot."
  echo
  if (( quarantine_enabled )); then
    echo "Quarantine: ON (releases held until ${quarantine_days} days old)."
  else
    echo "Quarantine: **OFF** — latest release imported immediately by override."
  fi
  echo
  echo "## Imported releases"
  for entry in "${updated[@]}"; do echo "- \`${entry}\`"; done
  if (( ${#quarantined[@]} > 0 )); then
    echo
    echo "## Still quarantined"
    for entry in "${quarantined[@]}"; do echo "- ${entry}"; done
  fi
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

title="chore(vendor): release sync $(date -u +%F) (${#updated[@]} upstream$( ((${#updated[@]}>1)) && echo s ))"
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
