#!/usr/bin/env bash
set -euo pipefail

commit="$(git rev-parse --verify HEAD)"
if ! git diff --quiet --ignore-submodules HEAD -- ||
  [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  commit="${commit}-dirty"
fi

printf 'STABLE_AGENT_OS_COMMIT %s\n' "$commit"
