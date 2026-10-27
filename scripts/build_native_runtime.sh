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

for tool in xcodebuild xcrun python3; do
  command -v "$tool" >/dev/null || { echo "Missing build dependency: $tool" >&2; exit 2; }
done

KIT_ARGS=()
if [[ "${IDECK_BUILD_WOW64:-0}" == "1" ]]; then KIT_ARGS+=(--wow64); fi
if [[ "${IDECK_BUNDLE_WINE_MONO:-0}" == "1" ]]; then KIT_ARGS+=(--mono); fi
REPO_KIT="$(python3 scripts/madeira_native_kit.py path "${KIT_ARGS[@]}")"
CACHE_KIT="$(python3 scripts/madeira_native_kit.py path --cache "${KIT_ARGS[@]}")"
if [[ "${IDECK_PREBUILT_MODE:-prefer}" == "off" || ( ! -s "$REPO_KIT" && ! -s "$CACHE_KIT" ) ]]; then
  for tool in git cmake ninja meson; do
    command -v "$tool" >/dev/null || { echo "Missing native build dependency: $tool" >&2; exit 2; }
  done
  if [[ ! -f vendor/Madeira/app/Madeira/FEXBridge.mm ]]; then
    bash scripts/fetch_madeira_sources.sh
  fi
fi

IDECK_REQUIRE_MADEIRA=1 bash scripts/build_ipa.sh
