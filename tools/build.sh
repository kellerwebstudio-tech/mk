#!/usr/bin/env bash
# Builds the place file with Rojo: build/DeliveryDashCity.rbxl
# Usage: bash tools/build.sh
#   DDC_TOOLS=/path/to/dir   directory containing `rojo` (otherwise `rojo` from PATH)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ -n "${DDC_TOOLS:-}" && -x "${DDC_TOOLS}/rojo" ]]; then
  ROJO="${DDC_TOOLS}/rojo"
elif command -v rojo >/dev/null 2>&1; then
  ROJO="$(command -v rojo)"
else
  echo "tools/build.sh: rojo not found. Set DDC_TOOLS=<dir containing rojo> or put rojo on PATH." >&2
  exit 2
fi

mkdir -p build
"$ROJO" build default.project.json -o build/DeliveryDashCity.rbxl
echo "built build/DeliveryDashCity.rbxl"
