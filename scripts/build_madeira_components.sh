#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$ROOT/vendor/Madeira"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: Building iOS-native Madeira components requires macOS and Xcode." >&2
  exit 2
fi

for tool in xcrun xcodebuild cmake ninja python3 git; do
  command -v "$tool" >/dev/null || { echo "ERROR: missing build tool: $tool" >&2; exit 2; }
done

if [[ ! -d "$UPSTREAM/.git" ]]; then
  echo "ERROR: Madeira sources not checked out. Run scripts/fetch_madeira_sources.sh" >&2
  exit 2
fi

for submodule in FEX wine dxmt; do
  if [[ ! -e "$UPSTREAM/$submodule/.git" ]]; then
    echo "ERROR: Madeira submodule $submodule missing; use git -C vendor/Madeira submodule update --init --recursive" >&2
    exit 2
  fi
done

if [[ ! -d "$UPSTREAM/toolchains/llvm-ios-build" ]]; then
  echo "ERROR: Madeira iOS toolchain missing: vendor/Madeira/toolchains/llvm-ios-build" >&2
  echo "Read vendor/Madeira/docs/BUILDING.md for required toolchain and licensed dependencies." >&2
  exit 2
fi

echo "[1/4] Building Madeira's iOS FEX native archives..."
bash scripts/build_fex.sh

echo "[2/4] Building Madeira's iOS Wine ntdll unix bridge..."
bash scripts/build_wine.sh

echo "[3/4] Building Madeira's iOS DXMT native archive..."
bash scripts/build_dxmt.sh

echo "[4/4] Building Madeira's ARM64EC D3D12 PE libraries..."
bash scripts/build_d3d12.sh

echo "Native build stages completed; checking outputs."
required=(
  "$UPSTREAM/FEX/build-ios/FEXCore/Source/libFEXCore.a"
  "$UPSTREAM/FEX/build-ios/FEXCore/Source/libFEXCore_Base.a"
  "$UPSTREAM/app/Madeira/libdxmt_combined.a"
  "$UPSTREAM/app/Madeira/arm64ec-windows/d3d12.dll"
  "$UPSTREAM/app/Madeira/arm64ec-windows/d3d12core.dll"
  "$UPSTREAM/app/Madeira/arm64ec-windows/xtajit64.dll"
  "$UPSTREAM/app/Madeira/aarch64-windows/d3d11.dll"
  "$UPSTREAM/app/Madeira/aarch64-windows/dxgi.dll"
)
missing=0
for artifact in "${required[@]}"; do
  if [[ ! -s "$artifact" ]]; then
    echo "ERROR: required Madeira build output missing: $artifact" >&2
    missing=1
  fi
done

if (( missing )); then
  echo "These components are not complete. Wine ARM64EC PE build and FEX ARM64EC guest DLL farm may require additional upstream build steps." >&2
  exit 3
fi

echo "Found selected native archives and PE DLLs."
echo "NOT LINKED: iDeck.xcodeproj still requires actual Madeira app bridge sources,"
echo "FEX/Wine/DXMT archives, frameworks, and runtime resources in its linker inputs."
echo "Do not enable IDECK_NATIVE_MADEIRA_ENABLED until those links and on-device tests are completed."
