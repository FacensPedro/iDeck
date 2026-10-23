#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Native iOS compilation requires macOS and Xcode." >&2
  exit 2
fi
command -v xcodebuild >/dev/null || { echo "xcodebuild not found" >&2; exit 2; }
command -v xcrun >/dev/null || { echo "xcrun not found" >&2; exit 2; }
if [[ ! -d vendor/Madeira ]]; then
  echo "Madeira sources missing. Run bash scripts/fetch_madeira_sources.sh" >&2
  exit 2
fi
echo "Madeira sources detected. Verifying source components..."
for path in vendor/Madeira/app/Madeira/FEXBridge.h vendor/Madeira/app/Madeira/WineServerBridge.h vendor/Madeira/app/Madeira/WineProcessBridge.h; do
  [[ -f "$path" ]] || { echo "Missing: $path" >&2; exit 2; }
done
echo "Source checks passed."
echo "Native FEX/Wine/DXMT/D3D12 cross-builds must follow upstream Madeira's build instructions."
echo "This script does not mark the runtime ready or create placeholder archives."
if [[ "${IDECK_BUILD_INTERFACE_ONLY:-0}" == "1" ]]; then
  bash scripts/build_ipa.sh
else
  echo "Refusing to advertise an unbuilt Madeira runtime. Set IDECK_BUILD_INTERFACE_ONLY=1 to build the interface-only IPA." >&2
  exit 3
fi
