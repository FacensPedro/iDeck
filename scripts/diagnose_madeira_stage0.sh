#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REPORT="$ROOT/build/diagnostics/madeira-stage0"
mkdir -p "$REPORT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: Stage 0 requires an actual macOS/Xcode runner." >&2
  exit 2
fi

{
  printf 'iDeck Madeira — Stage 0 (clean macOS runner)\n'
  printf 'Repository commit: '
  git rev-parse HEAD
  printf 'Host: '
  uname -a
  for command_name in git cmake meson ninja clang llvm-config xcodebuild xcrun bison; do
    if command -v "$command_name" >/dev/null 2>&1; then
      printf 'AVAILABLE %-14s %s\n' "$command_name" "$(command -v "$command_name")"
    else
      printf 'MISSING   %-14s\n' "$command_name"
    fi
  done
  if command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild -version
  fi
  if command -v xcrun >/dev/null 2>&1; then
    xcrun --sdk iphoneos --show-sdk-version || true
    xcrun --sdk iphoneos --show-sdk-path || true
    xcrun --sdk iphoneos --find clang || true
    xcrun --sdk macosx --find metal || true
  fi
  if command -v bison >/dev/null 2>&1; then
    bison --version | head -n 1
  fi
  printf '\nOptional binary input inventory before fetch:\n'
  if [[ -d "$ROOT/vendor/Madeira" ]]; then
    find "$ROOT/vendor/Madeira/toolchains" -maxdepth 1 -type d 2>/dev/null || true
  else
    echo 'No preexisting vendor/Madeira tree'
  fi
} 2>&1 | tee "$REPORT/toolchains.txt"

echo "=== Running exact pinned Madeira fetch, including submodules and iDeck patches ==="
bash scripts/fetch_madeira_sources.sh 2>&1 | tee "$REPORT/fetch.txt"

MD="$ROOT/vendor/Madeira"
PIN="fd9f2f3d0434a4116e4c3351f286a0fc376b4e36"
ACTUAL="$(git -C "$MD" rev-parse HEAD)"
[[ "$ACTUAL" == "$PIN" ]] || {
  echo "ERROR: Madeira revision mismatch: $ACTUAL != $PIN" >&2
  exit 2
}
[[ -f "$MD/docs/BUILDING.md" ]] || {
  echo "ERROR: pinned Madeira/docs/BUILDING.md missing" >&2
  exit 2
}
{
  echo "Pinned Madeira commit: $ACTUAL"
  git -C "$MD" submodule status --recursive
  echo "README / pinned BUILDING.md development inputs:"
  sed -n '1,85p' "$MD/docs/BUILDING.md"
} > "$REPORT/madeira-revisions-and-building.txt"

for path in \
  "$MD/FEX/.git" \
  "$MD/wine/.git" \
  "$MD/dxmt/.git" \
  "$MD/app/Madeira/FEXBridge.mm" \
  "$MD/app/Madeira/WineServerBridge.m" \
  "$MD/app/Madeira/WineProcessBridge.m" \
  "$MD/build/fex-arm64ec/build.sh" \
  "$MD/build/wineserver/build.sh" \
  "$MD/build/ntdll-unix/build.sh" \
  "$MD/build/win32u-unix/build.sh" \
  "$MD/build/madeira-d3d12/build-pe.sh"; do
  if [[ ! -e "$path" ]]; then
    echo "ERROR: required pinned Madeira source is missing: $path" >&2
    exit 2
  fi
done
[[ "$(tr -d '\r\n' < "$MD/wine/VERSION")" == "Wine version 11.4" ]] || {
  echo "ERROR: pinned upstream Wine version is not 11.4" >&2
  exit 2
}

printf 'Missing generated/development prerequisites (not substituted):\n' | tee "$REPORT/inputs.txt"
for path in \
  "$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/arm64ec-w64-mingw32-clang" \
  "$MD/toolchains/llvm-ios-build/include/llvm/Config/llvm-config.h" \
  "$MD/toolchains/gnutls-ios/include/gnutls/gnutls.h" \
  "$MD/toolchains/ffmpeg-ios/include/libavcodec/avcodec.h" \
  "$MD/app/Madeira/d3d12/libmetalirconverter.dylib"; do
  if [[ -s "$path" ]]; then
    echo "PRESENT $path" | tee -a "$REPORT/inputs.txt"
  else
    echo "MISSING $path" | tee -a "$REPORT/inputs.txt"
  fi
done

echo "=== Building interface-only baseline (never setting native compile flags) ==="
IDECK_REQUIRE_MADEIRA=0 bash scripts/build_ipa.sh 2>&1 | tee "$REPORT/interface-build.txt"
APP="$ROOT/build/Build/Products/Release-iphoneos/iDeck.app"
[[ -s "$APP/iDeck" && -s "$ROOT/iDeck.ipa" ]] || {
  echo "ERROR: interface-only IPA or compiled app is missing" >&2
  exit 2
}

echo "=== Capturing STRICT pre-native verifier baseline (expected failure) ==="
set +e
python3 scripts/verify_madeira_bundle.py --app "$APP" --require 2>&1 | tee "$REPORT/native-required-baseline.txt"
STATUS="${PIPESTATUS[0]}"
set -e
if [[ "$STATUS" -eq 0 ]]; then
  echo "ERROR: interface-only app unexpectedly passed the strict native verifier" >&2
  exit 2
fi
grep -Fq 'Native runtime build FAILED verification.' "$REPORT/native-required-baseline.txt" || {
  echo "ERROR: strict verifier failed without its expected validation diagnostics" >&2
  exit 2
}

echo "=== Checking that optional verifier does not mark the interface as native ==="
python3 scripts/verify_madeira_bundle.py --app "$APP" 2>&1 | tee "$REPORT/interface-verifier.txt"
[[ ! -e "$APP/MadeiraRuntimeManifest.plist" ]] || {
  echo "ERROR: interface-only app incorrectly received a native Madeira manifest" >&2
  exit 2
}

echo "PASS: Stage 0 verified at pinned Madeira $PIN; native verification correctly rejected interface-only IPA."
