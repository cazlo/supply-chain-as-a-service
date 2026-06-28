#!/usr/bin/env bash
set -euo pipefail

readonly imports=(
  "artifact-keeper:ea6f5ed686ea2783bcaddd67c9e22bcb66d607a8"
  "artifact-keeper-web:3cfc8dd6665969bf53aa34481ac1268c540b8cc6"
  "artifact-keeper-iac:19fddefd17d91df77ecad0526f388655435545ef"
)

for import in "${imports[@]}"; do
  prefix="${import%%:*}"
  revision="${import#*:}"

  git cat-file -e "${revision}^{commit}"
  if ! git diff --quiet "${revision}^{tree}" "HEAD:${prefix}"; then
    echo "${prefix} differs from recorded upstream revision ${revision}" >&2
    git diff --stat "${revision}^{tree}" "HEAD:${prefix}" >&2
    exit 1
  fi

  echo "${prefix}: ${revision} (clean)"
done
