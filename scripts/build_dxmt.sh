#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/vendor/Madeira/build/dxmt-ios/build.sh"
[[ "$(uname -s)" == "Darwin" ]] || { echo "Requires macOS/Xcode" >&2; exit 2; }
[[ -f "$SOURCE" ]] || { echo "Missing Madeira DXMT build script. Run scripts/fetch_madeira_sources.sh" >&2; exit 2; }
command -v xcrun >/dev/null || { echo "Missing Xcode command line tools" >&2; exit 2; }
cd "$(dirname "$SOURCE")"
bash "$SOURCE" "$@"
