#!/usr/bin/env bash
# Static analysis: rojo sourcemap + luau-lsp analyze with Roblox global types.
# Usage: bash tools/analyze.sh [extra luau-lsp args]
#   DDC_TOOLS=/path/to/dir   directory containing `rojo`, `luau-lsp` (and optionally globalTypes.d.luau)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

find_tool() {
  local name="$1"
  if [[ -n "${DDC_TOOLS:-}" && -x "${DDC_TOOLS}/${name}" ]]; then
    echo "${DDC_TOOLS}/${name}"
  elif command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
  else
    echo "tools/analyze.sh: '$name' not found. Set DDC_TOOLS=<dir> or put it on PATH." >&2
    exit 2
  fi
}

ROJO="$(find_tool rojo)"
LSP="$(find_tool luau-lsp)"

CACHE_DIR="tools/.cache"
TYPES="${CACHE_DIR}/globalTypes.d.luau"
mkdir -p "$CACHE_DIR"
if [[ ! -s "$TYPES" ]]; then
  if [[ -n "${DDC_TOOLS:-}" && -s "${DDC_TOOLS}/globalTypes.d.luau" ]]; then
    cp "${DDC_TOOLS}/globalTypes.d.luau" "$TYPES"
  else
    URL="https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"
    echo "tools/analyze.sh: downloading globalTypes.d.luau ..."
    curl -fsSL "$URL" -o "$TYPES" || { echo "download failed; set DDC_TOOLS to a dir containing globalTypes.d.luau" >&2; exit 2; }
  fi
fi

"$ROJO" sourcemap default.project.json -o sourcemap.json
exec "$LSP" analyze \
  --definitions="$TYPES" \
  --sourcemap=sourcemap.json \
  --base-luaurc=.luaurc \
  --ignore="tests/**" \
  --ignore="**/_Index/**" \
  "$@" \
  src
