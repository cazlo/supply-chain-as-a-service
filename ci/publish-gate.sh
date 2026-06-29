#!/usr/bin/env bash
set -euo pipefail

# Decide whether publish-ci should run the secretless validation path or the
# publish/scan/sign/smoke path. For issue_comment events, `/deploy smoke` is an
# explicit ChatOps authorization for the current immutable PR head.

readonly output="${GITEA_OUTPUT:?GITEA_OUTPUT is required}"
readonly event="${GITEA_EVENT_NAME:?GITEA_EVENT_NAME is required}"
readonly bot_login="${BOT_LOGIN:-supply-chain-sync}"
readonly base_branch="${BASE_BRANCH:-main}"

emit() { printf '%s=%s\n' "$1" "$2" >>"${output}"; }
die() { echo "error: $*" >&2; exit 1; }

run=true
publish=true
checkout_ref="${GITEA_EVENT_SHA:-}"
pr_number="${PR_NUMBER:-}"

case "${event}" in
  pull_request)
    [[ -n "${checkout_ref}" ]] || die "pull_request event is missing its head SHA"
    if [[ "${PR_AUTHOR:-}" == "${bot_login}" ]]; then
      publish=false
      echo "bot-authored PR by ${PR_AUTHOR}: validate-only, no publish or deploy"
    fi
    ;;

  workflow_dispatch)
    [[ -n "${checkout_ref}" ]] || die "workflow_dispatch event is missing its ref SHA"
    ;;

  issue_comment)
    # Every ordinary PR comment triggers this lightweight gate. Only a newly
    # created, exact command proceeds to jobs that can receive publish secrets.
    run=false
    publish=false
    checkout_ref=""

    command="$(printf '%s' "${COMMENT_BODY:-}" |
      sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "${GITEA_EVENT_ACTION:-}" != "created" || "${command}" != "/deploy smoke" ]]; then
      echo "ignoring non-deploy comment"
    else
      [[ -n "${GITEA_TOKEN:-}" ]] || die "GITEA_TOKEN is required for ChatOps authorization"
      [[ -n "${GITEA_SERVER_URL:-}" ]] || die "GITEA_SERVER_URL is required"
      [[ "${GITEA_REPOSITORY:-}" == */* ]] || die "invalid GITEA_REPOSITORY"
      [[ "${pr_number}" =~ ^[0-9]+$ ]] || die "/deploy smoke must be used on a pull request"
      [[ -n "${COMMENT_AUTHOR:-}" ]] || die "comment author is missing"
      [[ "${COMMENT_AUTHOR}" != "${bot_login}" ]] || die "the sync bot cannot authorize deployments"

      # The built-in Gitea job token can read PRs but intentionally cannot read
      # collaborator permissions. Default to the individual repository owner;
      # additional trusted operators can be named explicitly in the non-secret
      # CHATOPS_DEPLOYERS repository variable (comma- or space-separated).
      owner="${GITEA_REPOSITORY%%/*}"
      deployers="${CHATOPS_DEPLOYERS:-${owner}}"
      deployers="${deployers//,/ }"
      read -r -a authorized_users <<<"${deployers}"
      authorized=false
      for user in "${authorized_users[@]}"; do
        if [[ "${COMMENT_AUTHOR}" == "${user}" ]]; then
          authorized=true
          break
        fi
      done
      [[ "${authorized}" == true ]] ||
        die "${COMMENT_AUTHOR} is not listed in CHATOPS_DEPLOYERS"

      api="${GITEA_SERVER_URL%/}/api/v1/repos/${GITEA_REPOSITORY}"
      pr="$(curl -fsS -H "Authorization: token ${GITEA_TOKEN}" \
        "${api}/pulls/${pr_number}")"
      state="$(jq -r '.state' <<<"${pr}")"
      head_repo="$(jq -r '.head.repo.full_name' <<<"${pr}")"
      target="$(jq -r '.base.ref' <<<"${pr}")"
      checkout_ref="$(jq -r '.head.sha' <<<"${pr}")"

      [[ "${state}" == "open" ]] || die "PR #${pr_number} is not open"
      [[ "${head_repo}" == "${GITEA_REPOSITORY}" ]] || die "fork PRs cannot receive deployment secrets"
      [[ "${target}" == "${base_branch}" ]] || die "PR #${pr_number} does not target ${base_branch}"
      [[ "${checkout_ref}" =~ ^[0-9a-f]{40}$ ]] || die "PR #${pr_number} has an invalid head SHA"

      run=true
      publish=true
      echo "accepted /deploy smoke from ${COMMENT_AUTHOR} for PR #${pr_number} at ${checkout_ref}"
    fi
    ;;

  *)
    die "unsupported event: ${event}"
    ;;
esac

emit run "${run}"
emit publish "${publish}"
emit checkout_ref "${checkout_ref}"
emit pr_number "${pr_number}"
