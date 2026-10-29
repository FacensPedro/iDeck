#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
SOURCE="$MD/build/dxmt-ios/build.sh"
[[ "$(uname -s)" == "Darwin" ]] || { echo "Requires macOS/Xcode" >&2; exit 2; }
[[ -f "$SOURCE" ]] || { echo "Missing Madeira DXMT build script. Run scripts/fetch_madeira_sources.sh" >&2; exit 2; }
command -v xcrun >/dev/null || { echo "Missing Xcode command line tools" >&2; exit 2; }
bash "$ROOT/scripts/prepare_madeira_toolchains.sh"
bash "$ROOT/scripts/verify_dxmt_llvm.sh"
cd "$(dirname "$SOURCE")"
bash "$SOURCE" "$@"
