#!/usr/bin/env bash
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
readonly metadata="${root}/vendor/upstreams.tsv"

usage() {
  cat <<'EOF'
Usage:
  ci/subtree-sync.sh check [name ...]
  ci/subtree-sync.sh status [name ...]
  ci/subtree-sync.sh update <name> <reviewed-ref> [tag]

Commands:
  check   Compare each vendored tree with its recorded commit; no network.
  status  Fetch each default branch and report commits available upstream.
  update  Merge one reviewed ref as a full-history subtree and update its lock.

The update command requires a clean worktree and a fast-forward upstream
revision. It signs the subtree merge and provenance commits. Pass '-' when the
reviewed revision has no release tag.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

validate_metadata() {
  [[ -f "${metadata}" ]] || die "missing ${metadata}"
  [[ "$(head -n 1 "${metadata}")" == $'name\tprefix\turl\tbranch\trevision\ttag\timported' ]] ||
    die "unexpected metadata header"

  local name prefix url branch revision tag imported extra
  while IFS=$'\t' read -r name prefix url branch revision tag imported extra; do
    [[ "${name}" == "name" ]] && continue
    [[ -n "${name}" ]] || continue
    [[ -z "${extra:-}" ]] || die "too many fields for ${name}"
    [[ "${name}" =~ ^[a-z0-9-]+$ ]] || die "invalid name: ${name}"
    [[ "${prefix}" =~ ^[a-z0-9-]+$ ]] || die "invalid prefix for ${name}"
    [[ "${url}" == https://github.com/artifact-keeper/*.git ]] || die "unexpected URL for ${name}"
    [[ "${branch}" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid branch for ${name}"
    [[ "${revision}" =~ ^[0-9a-f]{40}$ ]] || die "invalid revision for ${name}"
    [[ "${tag}" == "-" ]] || git check-ref-format "refs/tags/${tag}" >/dev/null || die "invalid tag for ${name}"
    [[ "${imported}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "invalid import date for ${name}"
  done < "${metadata}"
}

load_upstream() {
  local requested="$1"
  local row
  row="$(awk -F '\t' -v name="${requested}" '$1 == name { print; exit }' "${metadata}")"
  [[ -n "${row}" ]] || die "unknown upstream: ${requested}"
  IFS=$'\t' read -r upstream_name upstream_prefix upstream_url upstream_branch upstream_revision upstream_tag upstream_imported <<< "${row}"
}

selected_names() {
  if (( $# > 0 )); then
    printf '%s\n' "$@"
  else
    awk -F '\t' 'NR > 1 && NF { print $1 }' "${metadata}"
  fi
}

check_one() {
  load_upstream "$1"
  git cat-file -e "${upstream_revision}^{commit}" 2>/dev/null ||
    die "${upstream_name}: recorded commit is missing from local history"
  git merge-base --is-ancestor "${upstream_revision}" HEAD ||
    die "${upstream_name}: recorded commit is not reachable from HEAD"
  [[ -f "${upstream_prefix}/LICENSE" ]] || die "${upstream_name}: LICENSE is missing"

  if ! git diff --quiet "${upstream_revision}^{tree}" "HEAD:${upstream_prefix}"; then
    echo "${upstream_name}: vendored tree differs from ${upstream_revision}" >&2
    git diff --stat "${upstream_revision}^{tree}" "HEAD:${upstream_prefix}" >&2
    return 1
  fi

  echo "${upstream_name}: ${upstream_revision} (clean)"
}

status_one() {
  load_upstream "$1"
  local latest_ref="refs/vendor-sync/${upstream_name}/latest"
  git fetch --quiet --no-tags "${upstream_url}" "+${upstream_branch}:${latest_ref}"
  local latest
  latest="$(git rev-parse "${latest_ref}^{commit}")"

  if [[ "${latest}" == "${upstream_revision}" ]]; then
    echo "${upstream_name}: current at ${latest}"
  elif git merge-base --is-ancestor "${upstream_revision}" "${latest}"; then
    local count
    count="$(git rev-list --count "${upstream_revision}..${latest}")"
    echo "${upstream_name}: ${count} commit(s) available; ${upstream_revision} -> ${latest}"
  else
    echo "${upstream_name}: upstream diverged; review ${upstream_revision} -> ${latest}" >&2
    return 1
  fi
}

update_metadata() {
  local name="$1" revision="$2" tag="$3" imported="$4"
  local temporary
  temporary="$(mktemp "${metadata}.XXXXXX")"
  awk -F '\t' -v OFS='\t' -v name="${name}" -v revision="${revision}" -v tag="${tag}" -v imported="${imported}" '
    $1 == name { $5 = revision; $6 = tag; $7 = imported }
    { print }
  ' "${metadata}" > "${temporary}"
  mv "${temporary}" "${metadata}"
}

verify_tag() {
  local url="$1" tag="$2" expected="$3"
  [[ "${tag}" == "-" ]] && return
  git check-ref-format "refs/tags/${tag}" >/dev/null || die "invalid tag: ${tag}"

  local tag_target
  tag_target="$(git ls-remote --tags "${url}" "refs/tags/${tag}" "refs/tags/${tag}^{}" | awk '
    $2 ~ /\^\{\}$/ { peeled = $1 }
    $2 !~ /\^\{\}$/ { direct = $1 }
    END { print peeled ? peeled : direct }
  ')"
  [[ -n "${tag_target}" ]] || die "tag does not exist upstream: ${tag}"
  [[ "${tag_target}" == "${expected}" ]] ||
    die "tag ${tag} resolves to ${tag_target}, not reviewed commit ${expected}"
}

update_one() {
  local name="$1" reviewed_ref="$2" reviewed_tag="${3:--}"
  load_upstream "${name}"

  [[ -z "$(git status --porcelain)" ]] || die "update requires a clean worktree"
  [[ -z "$(git rev-parse -q --verify MERGE_HEAD 2>/dev/null || true)" ]] || die "a merge is already in progress"

  local candidate_ref="refs/vendor-sync/${upstream_name}/candidate"
  git fetch --quiet --no-tags "${upstream_url}" "+${reviewed_ref}:${candidate_ref}"
  local candidate
  candidate="$(git rev-parse "${candidate_ref}^{commit}")"
  verify_tag "${upstream_url}" "${reviewed_tag}" "${candidate}"

  if [[ "${candidate}" == "${upstream_revision}" ]]; then
    echo "${upstream_name}: already pinned at ${candidate}"
    return
  fi
  git merge-base --is-ancestor "${upstream_revision}" "${candidate}" ||
    die "${upstream_name}: ${candidate} is not a fast-forward from ${upstream_revision}"

  git subtree merge --prefix="${upstream_prefix}" -m "chore(vendor): sync ${upstream_name} to ${candidate:0:12}" "${candidate}"
  git commit --amend --no-edit -S

  update_metadata "${upstream_name}" "${candidate}" "${reviewed_tag}" "$(date -u +%F)"
  git add "${metadata}"
  git commit -S -m "chore(vendor): record ${upstream_name} provenance"
  check_one "${upstream_name}"

  echo "${upstream_name}: updated to ${candidate}; review and push the two signed commits"
}

main() {
  cd "${root}"
  validate_metadata

  local command="${1:-}"
  case "${command}" in
    check|status)
      shift
      local name
      while IFS= read -r name; do
        "${command}_one" "${name}"
      done < <(selected_names "$@")
      ;;
    update)
      (( $# == 3 || $# == 4 )) || { usage >&2; exit 2; }
      update_one "$2" "$3" "${4:--}"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
