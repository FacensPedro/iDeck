#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
REBUILD="${IDECK_MADEIRA_REBUILD:-1}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "ERROR: iOS native toolchains require macOS." >&2; exit 2; }
for tool in xcrun xcodebuild cmake ninja meson python3; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required by Madeira." >&2; exit 2; }
done

for toolchain in "$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/arm64ec-w64-mingw32-clang" \
                 "$MD/toolchains/llvm-ios-build/lib"; do
  [[ -e "$toolchain" ]] || { echo "ERROR: missing required Madeira toolchain: $toolchain" >&2; exit 2; }
done

if ! xcrun --sdk iphoneos --find clang >/dev/null 2>&1; then
  echo "ERROR: iPhoneOS SDK is not installed in Xcode." >&2
  exit 2
fi

if [[ ! -f "$MD/app/Madeira/FEXBridge.mm" ]]; then
  echo "ERROR: pinned Madeira checkout missing; run bash scripts/fetch_madeira_sources.sh" >&2
  exit 2
fi
for component in FEX wine dxmt; do
  [[ -e "$MD/$component/.git" ]] || { echo "ERROR: unpublished or missing Madeira $component submodule. Check upstream refs." >&2; exit 2; }
done

if [[ "$REBUILD" == "1" ]]; then
  for src in "$MD/app/Madeira/libgmp.a" "$MD/app/Madeira/libnettle.a" "$MD/app/Madeira/libhogweed.a" "$MD/app/Madeira/libgnutls.a"; do
    if [[ ! -s "$src" ]]; then
      bash "$MD/build/gnutls-ios/build.sh"
      break
    fi
  done
  for src in "$MD/app/Madeira/libavformat.a" "$MD/app/Madeira/libavcodec.a" "$MD/app/Madeira/libswresample.a" "$MD/app/Madeira/libavutil.a"; do
    if [[ ! -s "$src" ]]; then
      bash "$MD/build/ffmpeg/build.sh"
      break
    fi
  done

  bash "$MD/build/fex-ios/build.sh"
  bash "$MD/build/fex-arm64ec/build.sh"
  bash "$MD/build/wine-pe/build-ntdll.sh"
  [[ -s "$MD/app/Madeira/arm64ec-windows/ntdll.dll" ]] || {
    echo "ERROR: Wine ARM64EC ntdll.dll was not generated." >&2; exit 2;
  }
  if [[ "${IDECK_REBUILD_WINE_PE_MODULES:-0}" == "1" ]]; then
    bash "$MD/build/wine-pe/build-modules.sh"
  fi
  [[ -f "$MD/wine/build-arm64ec/config.status" ]] || {
    echo "ERROR: Wine ARM64EC configure did not complete." >&2; exit 2;
  }
  if [[ ! -s "$MD/wine/build-macos/include/config.h" ]]; then
    mkdir -p "$MD/wine/build-macos"
    (cd "$MD/wine/build-macos" && ../configure --without-x --disable-tests)
  fi
  bash "$MD/build/ntdll-unix/build.sh"
  bash "$MD/build/wineserver/build.sh"
  bash "$MD/build/win32u-unix/build.sh"

  bash "$MD/build/dxmt-ios/build.sh"
  COMBINED="$MD/build/dxmt-ios/libdxmt_combined.a"
  if [[ ! -s "$COMBINED" ]]; then
    LLVM_LIBS=("$MD/toolchains/llvm-ios-build/lib/"*.a)
    DXMT_OBJS=("$MD/build/dxmt-ios/obj/"*.o)
    [[ -s "${LLVM_LIBS[0]}" && -s "${DXMT_OBJS[0]}" ]] || {
      echo "ERROR: cross-built iOS LLVM static archives or DXMT objects are missing." >&2
      exit 2
    }
    xcrun --sdk iphoneos libtool -static -o "$COMBINED" "${DXMT_OBJS[@]}" "${LLVM_LIBS[@]}"
  fi
  cp "$COMBINED" "$MD/app/Madeira/libdxmt_combined.a"

  # DXMT has both native iOS renderer code and Windows PE frontend modules.
  if [[ ! -e "$MD/dxmt/toolchains" ]]; then
    ln -s ../toolchains "$MD/dxmt/toolchains"
  fi
  if [[ ! -f "$MD/dxmt/build-pe/build.ninja" ]]; then
    (cd "$MD/dxmt" && SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
      PATH="$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:/usr/bin:/opt/homebrew/bin:$PATH" \
      meson setup --cross-file build-aarch64-win.txt --native-file build-osx.txt \
        -Dwine_build_path=../../wine/build-macos build-pe)
  fi
  (cd "$MD/dxmt" && SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    PATH="$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:/usr/bin:/opt/homebrew/bin:$PATH" \
    meson compile -C build-pe)
  for name in d3d11/d3d11.dll dxgi/dxgi.dll winemetal/winemetal.dll d3d10/d3d10core.dll; do
    src="$MD/dxmt/build-pe/src/$name"
    [[ -s "$src" ]] || { echo "ERROR: DXMT PE frontend missing: $src" >&2; exit 2; }
    cp "$src" "$MD/app/Madeira/aarch64-windows/${name##*/}"
  done

  if [[ ! -f "$MD/dxmt/build-arm64ec/build.ninja" ]]; then
    meson setup "$MD/dxmt/build-arm64ec" "$MD/dxmt" -Dbuildtype=release \
      -Dwine_build_path=../../wine/build-arm64ec \
      --cross-file="$MD/dxmt/build-arm64ec-win.txt"
  fi
  ninja -C "$MD/dxmt/build-arm64ec" src/winemetal/winemetal.dll
  WINEMETAL_EC="$MD/dxmt/build-arm64ec/src/winemetal/winemetal.dll"
  [[ -s "$WINEMETAL_EC" ]] || {
    echo "ERROR: WineMetal ARM64EC compilation produced no DLL." >&2; exit 2;
  }
  cp "$WINEMETAL_EC" "$MD/app/Madeira/arm64ec-windows/winemetal.dll"

  bash "$MD/build/madeira-d3d12/build-pe.sh"
  D3D="$MD/build/madeira-d3d12/out-pe"
  for name in madeira_d3d12.dll d3d12.dll d3d12core.dll; do
    [[ -s "$D3D/$name" ]] || { echo "ERROR: D3D12 output missing: $name" >&2; exit 2; }
    cp "$D3D/$name" "$MD/app/Madeira/arm64ec-windows/$name"
  done

fi

for file in \
  "$MD/FEX/build-ios/FEXCore/Source/libFEXCore.a" \
  "$MD/FEX/build-ios/FEXCore/Source/libFEXCore_Base.a" \
  "$MD/FEX/build-ios/FEXCore/Source/libJemallocLibs.a" \
  "$MD/app/Madeira/libntdll_unix.a" \
  "$MD/app/Madeira/libwineserver.a" \
  "$MD/app/Madeira/libwin32u_unix.a" \
  "$MD/app/Madeira/libdxmt_combined.a" \
  "$MD/app/Madeira/arm64ec-windows/xtajit64.dll" \
  "$MD/app/Madeira/arm64ec-windows/ntdll.dll" \
  "$MD/app/Madeira/aarch64-windows/winemetal.dll" \
  "$MD/app/Madeira/prefix-template.tar.gz" \
  "$MD/app/Madeira/arm64ec-windows/d3d12.dll" \
  "$MD/app/Madeira/arm64ec-windows/d3d12core.dll" \
  "$MD/app/Madeira/arm64ec-windows/winemetal.dll"; do
  [[ -s "$file" ]] || { echo "ERROR: missing compiled native/PE component: $file" >&2; exit 2; }
done

echo "Madeira FEX/Wine ARM64EC/DXMT/D3D12 native inputs are present."
echo "Next: build the upstream host bridge and link the iDeck app."
