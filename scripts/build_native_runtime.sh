#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${IDECK_BUILD_INTERFACE_ONLY:-0}" == "1" ]]; then
  IDECK_REQUIRE_MADEIRA=0 bash scripts/build_ipa.sh
  exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "Native FEXCore/Wine ARM64EC/DXMT/D3D12 compilation requires macOS and Xcode." >&2
  exit 2
}

for tool in xcodebuild xcrun git cmake ninja meson; do
  command -v "$tool" >/dev/null || { echo "Missing build dependency: $tool" >&2; exit 2; }
done

if [[ ! -f vendor/Madeira/app/Madeira/FEXBridge.mm ]]; then
  bash scripts/fetch_madeira_sources.sh
fi

IDECK_REQUIRE_MADEIRA=1 bash scripts/build_ipa.sh
