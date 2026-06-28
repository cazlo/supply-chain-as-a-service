#!/usr/bin/env bash
set -euo pipefail

readonly root="$(git rev-parse --show-toplevel)"
exec "${root}/ci/subtree-sync.sh" check "$@"
