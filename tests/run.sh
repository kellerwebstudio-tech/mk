#!/usr/bin/env bash
# Runs the offline Luau test suite: bundles the project + specs, then executes with the luau CLI.
# Usage: bash tests/run.sh [name-filter-pattern]
#   DDC_TOOLS=/path/to/dir   directory containing the `luau` binary (otherwise `luau` from PATH)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ -n "${DDC_TOOLS:-}" && -x "${DDC_TOOLS}/luau" ]]; then
  LUAU="${DDC_TOOLS}/luau"
elif command -v luau >/dev/null 2>&1; then
  LUAU="$(command -v luau)"
else
  echo "tests/run.sh: luau binary not found. Set DDC_TOOLS=<dir containing luau> or put luau on PATH." >&2
  exit 2
fi

python3 tools/bundle.py
if [[ $# -gt 0 ]]; then
  exec "$LUAU" tests/build/all.luau -a "$@"
else
  exec "$LUAU" tests/build/all.luau
fi
