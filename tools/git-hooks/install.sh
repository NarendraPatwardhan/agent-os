#!/usr/bin/env bash
set -euo pipefail

workspace="${BUILD_WORKSPACE_DIRECTORY:-}"
if [[ -z "$workspace" ]]; then
  workspace="$(git rev-parse --show-toplevel)"
fi

cd "$workspace"
git config core.hooksPath tools/git-hooks
echo "Configured Git hooks path: tools/git-hooks"
