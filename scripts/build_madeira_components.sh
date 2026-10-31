#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
REBUILD="${IDECK_MADEIRA_REBUILD:-1}"
STOP_AFTER="${IDECK_MADEIRA_STOP_AFTER:-all}"
[[ "$STOP_AFTER" == "fex" || "$STOP_AFTER" == "wine" || "$STOP_AFTER" == "dxmt" || "$STOP_AFTER" == "all" ]] || {
  echo "ERROR: IDECK_MADEIRA_STOP_AFTER must be fex, wine, dxmt or all." >&2
  exit 2
}
if [[ "$STOP_AFTER" != "all" && "$REBUILD" != "1" ]]; then
  echo "ERROR: partial native build stages require IDECK_MADEIRA_REBUILD=1." >&2
  exit 2
fi
GRAPHICS="${IDECK_MADEIRA_GRAPHICS:-d3d12}"
[[ "$GRAPHICS" == "d3d11" || "$GRAPHICS" == "d3d12" ]] || {
  echo "ERROR: IDECK_MADEIRA_GRAPHICS must be d3d11 or d3d12." >&2; exit 2;
}
[[ "${IDECK_BUILD_WOW64:-0}" == "0" || "${IDECK_BUILD_WOW64:-0}" == "1" ]] || {
  echo "ERROR: IDECK_BUILD_WOW64 must be 0 or 1." >&2
  exit 2
}
export IDECK_BUILD_WOW64="${IDECK_BUILD_WOW64:-0}"

[[ "$(uname -s)" == "Darwin" ]] || { echo "ERROR: iOS native toolchains require macOS." >&2; exit 2; }
for tool in xcrun xcodebuild cmake ninja meson python3; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required by Madeira." >&2; exit 2; }
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

[[ -s "$MD/wine/VERSION" ]] &&
[[ "$(tr -d '\r\n' < "$MD/wine/VERSION")" == "Wine version 11.4" ]] || {
  echo "ERROR: Madeira's pinned Wine 11.4 iOS/ARM64EC fork is required." >&2
  exit 2
}

# Wine configure requires GNU Bison >= 3.0. macOS ships Bison 2.3;
# source the preflight so the modern parser stays first on PATH for all
# later nested Wine/FEX/DXMT build scripts, including local builds.
if [[ "$REBUILD" == "1" && "$STOP_AFTER" != "fex" ]]; then
  source "$ROOT/scripts/ensure_madeira_bison.sh"
fi

bash "$ROOT/scripts/prepare_madeira_toolchains.sh"
if [[ "$STOP_AFTER" == "fex" ]]; then
  bash "$ROOT/scripts/verify_madeira_toolchains.sh"
else
  bash "$ROOT/scripts/verify_dxmt_llvm.sh"
fi

if [[ "$STOP_AFTER" == "all" || "$STOP_AFTER" == "dxmt" ]]; then
bash "$ROOT/scripts/ensure_metal_toolchain.sh"

# Validate the exact DXMT shader sources only when DXMT is being built.
DXMT_PREFLIGHT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ideck-dxmt-shaders.XXXXXXXX")"
for shader in air_msad air_samplepos air_tessellation; do
  if ! xcrun --sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 \
    -o "$DXMT_PREFLIGHT_DIR/$shader.air" -c "$MD/dxmt/src/airconv/shaders/$shader.metal"; then
    echo "ERROR: DXMT shader failed the Metal compiler preflight: $shader.metal" >&2
    rm -rf "$DXMT_PREFLIGHT_DIR"
    exit 2
  fi
  if [[ ! -s "$DXMT_PREFLIGHT_DIR/$shader.air" ]]; then
    echo "ERROR: DXMT shader generated no AIR bytecode: $shader.metal" >&2
    rm -rf "$DXMT_PREFLIGHT_DIR"
    exit 2
  fi
done
rm -rf "$DXMT_PREFLIGHT_DIR"
fi

if [[ "$REBUILD" == "1" ]]; then
  # Phase 3 builds FEX in isolation. GnuTLS, FFmpeg and FreeType are Wine
  # dependencies and must not cause an unrelated FEX JIT build to fail.
  # Full Wine/DXMT builds retain the exact dependency preparation path.
  if [[ "$STOP_AFTER" != "fex" ]]; then
    bash "$ROOT/scripts/prepare_madeira_dependencies.sh" "$MD"
  fi

  # FEX defaults TUNE_CPU to "native" and probes Linux /proc/cpuinfo.
  # A macOS runner building for iOS has no /proc/cpuinfo, so the FEX CPU
  # discovery scripts fail and CMake's string(STRIP ...) receives no value.
  # Disable host CPU tuning: the shipped binary must support Apple ARM64 devices,
  # not a guessed CPU type from the build runner.
  FEX_IOS_BUILD="$MD/FEX/build-ios"
  if [[ ! -f "$FEX_IOS_BUILD/CMakeCache.txt" ]]; then
    cmake -S "$MD/FEX" -B "$FEX_IOS_BUILD" -G Ninja \
      -DCMAKE_SYSTEM_NAME=iOS \
      -DCMAKE_SYSTEM_PROCESSOR=arm64 \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_SYSROOT=iphoneos \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
      -DCMAKE_BUILD_TYPE=Release \
      -DTUNE_CPU=none \
      -DBUILD_TESTING=OFF \
      -DBUILD_THUNKS=OFF \
      -DBUILD_FEXCONFIG=OFF \
      -DBUILD_FEX_LINUX_TESTS=OFF \
      -DENABLE_FEX_ALLOCATOR=OFF \
      -DENABLE_ASSERTIONS=OFF \
      -DENABLE_CLANG_THUNKS=ON \
      -DENABLE_CCACHE=ON
  else
    # Also repair caches from earlier unsuccessful configure attempts.
    cmake -S "$MD/FEX" -B "$FEX_IOS_BUILD" \
      -DCMAKE_SYSTEM_PROCESSOR=arm64 \
      -DTUNE_CPU=none
  fi
  bash "$MD/build/fex-ios/build.sh"
  bash "$ROOT/scripts/build_fex_ios_allocator.sh"
  bash "$MD/build/fex-arm64ec/build.sh"
  if [[ "$STOP_AFTER" == "fex" ]]; then
    for file in "$MD/FEX/build-ios/FEXCore/Source/libFEXCore.a" \
                "$MD/FEX/build-ios/FEXCore/Source/libFEXCore_Base.a" \
                "$MD/FEX/build-ios/FEXCore/Source/libJemallocLibs.a" \
                "$MD/app/Madeira/arm64ec-windows/xtajit64.dll"; do
      [[ -s "$file" ]] || { echo "ERROR: required FEX output not compiled: $file" >&2; exit 2; }
    done
    python3 "$ROOT/scripts/verify_madeira_component_outputs.py" --root "$MD" --stage fex
    echo "PASS: public FEX iPhoneOS ARM64 and ARM64EC JIT artifacts compiled; Wine/DXMT not yet validated."
    exit 0
  fi
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
  if [[ -f "$MD/tools/build/build-wine.sh" ]]; then
    # Newer Madeira configures build-macos itself (aarch64 PE, no FreeType
    # or GnuTLS in configure, winegstreamer on) and builds its tools. The
    # Unix libraries read this config.h, so it must match upstream exactly.
    ROOT="$MD" JOBS="$(sysctl -n hw.ncpu)" bash "$MD/tools/build/build-wine.sh"
  elif [[ ! -s "$MD/wine/build-macos/include/config.h" ]]; then
    mkdir -p "$MD/wine/build-macos"
    (cd "$MD/wine/build-macos" && \
      PATH="$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH" \
      ../configure --without-x --disable-tests)
  fi
  # configure creates config.h, but not the widl-generated SDK headers.
  # Build include targets in both trees used by the native Unix libraries.
  for wine_build in "$MD/wine/build-macos" "$MD/wine/build-arm64ec"; do
    PATH="$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH" \
      make -C "$wine_build" -j"$(sysctl -n hw.ncpu)" include/all
    for header in wtypes.h mfobjects.h mftransform.h dwrite.h dwrite_3.h; do
      [[ -s "$wine_build/include/$header" ]] || {
        echo "ERROR: generated Wine header missing: $wine_build/include/$header" >&2; exit 2;
      }
    done
  done
  NTDLL_LOG="$MD/build/ntdll-unix/build-ideck.log"
  if ! bash "$MD/build/ntdll-unix/build.sh" 2>&1 | tee "$NTDLL_LOG"; then
    FAILED_UNIXLIBS="$(sed -n 's/^Failed://p' "$NTDLL_LOG")"
    for name in $FAILED_UNIXLIBS; do
      ERR_FILE="$MD/build/ntdll-unix/obj/$name.err"
      if [[ -s "$ERR_FILE" ]]; then
        echo "=== compiler diagnostics: $name ===" >&2
        cat "$ERR_FILE" >&2
      fi
    done
    exit 1
  fi
  # Build a pinned GC64 interpreter-only LuaJIT, then compile the iOS
  # wineserver replacement mapper into the native static archive.
  bash "$ROOT/scripts/build_madeira_luajit.sh"
  bash "$MD/build/wineserver/build.sh"
  bash "$MD/build/win32u-unix/build.sh"
  if [[ "$STOP_AFTER" == "wine" ]]; then
    for file in "$MD/app/Madeira/libntdll_unix.a" \
                "$MD/app/Madeira/libwineserver.a" \
                "$MD/app/Madeira/libwin32u_unix.a" \
                "$MD/app/Madeira/arm64ec-windows/ntdll.dll" \
                "$MD/app/Madeira/arm64ec-windows/xtajit64.dll"; do
      [[ -s "$file" ]] || { echo "ERROR: required Wine ARM64EC output not compiled: $file" >&2; exit 2; }
    done
    python3 "$ROOT/scripts/verify_madeira_component_outputs.py" --root "$MD" --stage wine
    echo "PASS: public FEX and Wine Unix/wineserver/ARM64EC artifacts compiled; DXMT not yet validated."
    exit 0
  fi

  # airconv_context.cpp embeds AIR bitcode through these generated headers.
  # Match DXMT's Meson recipe: Metal -> AIR -> C array, without metallib.
  SHADER_HEADERS="$MD/build/dxmt-ios/shader-headers"
  mkdir -p "$SHADER_HEADERS"
  for shader in air_msad air_samplepos air_tessellation; do
    xcrun -sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 \
      -o "$SHADER_HEADERS/$shader.air" -c "$MD/dxmt/src/airconv/shaders/$shader.metal"
    xxd -n "$shader" -i "$SHADER_HEADERS/$shader.air" "$SHADER_HEADERS/$shader.h"
    [[ -s "$SHADER_HEADERS/$shader.h" ]] || {
      echo "ERROR: DXMT shader header missing: $shader.h" >&2; exit 2;
    }
  done
  DXMT_LOG="$MD/build/dxmt-ios/build-ideck.log"
  if ! bash "$MD/build/dxmt-ios/build.sh" 2>&1 | tee "$DXMT_LOG"; then
    FAILED_DXMT="$(sed -n 's/^Failed://p' "$DXMT_LOG")"
    for name in $FAILED_DXMT; do
      ERR_FILE="$MD/build/dxmt-ios/obj/$name.err"
      if [[ -s "$ERR_FILE" ]]; then
        echo "=== DXMT compiler diagnostics: $name ===" >&2
        cat "$ERR_FILE" >&2
      fi
    done
    exit 1
  fi
  COMBINED="$MD/build/dxmt-ios/libdxmt_combined.a"
  (
    LLVM_LIBS=("$MD/toolchains/llvm-ios-build/lib/"*.a)
    DXMT_OBJS=("$MD/build/dxmt-ios/obj/"*.o)
    [[ -s "${LLVM_LIBS[0]}" && -s "${DXMT_OBJS[0]}" ]] || {
      echo "ERROR: cross-built iOS LLVM static archives or DXMT objects are missing." >&2
      exit 2
    }
    xcrun --sdk iphoneos libtool -static -o "$COMBINED.new" "${DXMT_OBJS[@]}" "${LLVM_LIBS[@]}"
    mv "$COMBINED.new" "$COMBINED"
  )
  cp "$COMBINED" "$MD/app/Madeira/libdxmt_combined.a"

  # Meson links the Wine CRT and import libraries for each PE architecture.
  for arch in aarch64 arm64ec; do
    if [[ "$arch" == "aarch64" ]]; then
      WINE_PE_BUILD="$MD/wine/build-macos"
    else
      WINE_PE_BUILD="$MD/wine/build-arm64ec"
    fi
    PATH="$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH" \
      make -C "$WINE_PE_BUILD" -j"$(sysctl -n hw.ncpu)" \
        "libs/winecrt0/$arch-windows/libwinecrt0.a" \
        "dlls/ntdll/$arch-windows/libntdll.a" \
        "dlls/dbghelp/$arch-windows/libdbghelp.a" tools/winebuild/winebuild
  done

  # DXMT has both native iOS renderer code and Windows PE frontend modules.
  if [[ ! -e "$MD/dxmt/toolchains" ]]; then
    ln -s ../toolchains "$MD/dxmt/toolchains"
  fi
  if [[ ! -f "$MD/dxmt/build-pe/build.ninja" ]]; then
    (cd "$MD/dxmt" && SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" \
      PATH="$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:/usr/bin:/opt/homebrew/bin:$PATH" \
      meson setup --cross-file build-aarch64-win.txt --native-file build-osx.txt \
        -Dwine_build_path="$MD/wine/build-macos" build-pe)
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
      -Dwine_build_path="$MD/wine/build-arm64ec" \
      --cross-file="$MD/dxmt/build-arm64ec-win.txt"
  fi
  DXMT_EC_MODULES=(winemetal/winemetal.dll dxgi/dxgi.dll d3d11/d3d11.dll d3d10/d3d10core.dll)
  DXMT_EC_TARGETS=()
  for module in "${DXMT_EC_MODULES[@]}"; do
    DXMT_EC_TARGETS+=("src/$module")
  done
  ninja -C "$MD/dxmt/build-arm64ec" "${DXMT_EC_TARGETS[@]}"
  for module in "${DXMT_EC_MODULES[@]}"; do
    src="$MD/dxmt/build-arm64ec/src/$module"
    [[ -s "$src" ]] || {
      echo "ERROR: DXMT ARM64EC compilation produced no DLL: $module" >&2; exit 2;
    }
    cp "$src" "$MD/app/Madeira/arm64ec-windows/${module##*/}"
  done

  if [[ "$STOP_AFTER" == "dxmt" ]]; then
    python3 "$ROOT/scripts/verify_madeira_component_outputs.py" --root "$MD" --stage dxmt
    python3 "$ROOT/scripts/verify_madeira_dxmt_stage5.py" --root "$MD" --revision "${IDECK_MADEIRA_REV:-c2c1b03a9e36ef986c980b9eae3c14d05a372db1}"
    echo "PASS: full iOS DXMT and ARM64/ARM64EC D3D11 frontends compiled; D3D12, WoW64 and packaging not attempted."
    exit 0
  fi

  if [[ "${IDECK_BUILD_WOW64:-1}" == "1" ]]; then
    # Upstream's i386 Wine farm and the distinct FEX WOW64 translator.
    # Unlike xtajit64.dll, xtajit.dll executes PE32 x86 guest code.
    bash "$MD/build/fex-wow64/build.sh"
    bash "$MD/build/wine-i386/build.sh"
  fi

  if [[ "$GRAPHICS" == "d3d12" ]]; then
    bash "$MD/build/madeira-d3d12/build-pe.sh"
    D3D="$MD/build/madeira-d3d12/out-pe"
    for name in madeira_d3d12.dll d3d12.dll d3d12core.dll; do
      [[ -s "$D3D/$name" ]] || { echo "ERROR: D3D12 output missing: $name" >&2; exit 2; }
      cp "$D3D/$name" "$MD/app/Madeira/arm64ec-windows/$name"
    done
    cmp -s "$D3D/madeira_d3d12.dll" "$D3D/d3d12.dll" || {
      echo "ERROR: d3d12.dll is not the compiled madeira-d3d12 frontend." >&2
      exit 2
    }
  fi

  # Replace the pinned older dcomp.dll with upstream's source-level
  # DirectComposition composition-swapchain compatibility implementation.
  # Validate all PE exports before staging; never substitute a stub.
  bash "$ROOT/scripts/build_madeira_dcomp.sh"

  # OpenGL (Mesa OSMesa + Zink) and Vulkan (MoltenVK) host runtimes for gl/.
  bash "$ROOT/scripts/build_madeira_gl_vulkan.sh" "$MD"

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
  "$MD/app/Madeira/arm64ec-windows/d3d11.dll" \
  "$MD/app/Madeira/arm64ec-windows/dxgi.dll" \
  "$MD/app/Madeira/arm64ec-windows/d3d10core.dll" \
  "$MD/app/Madeira/aarch64-windows/winemetal.dll" \
  "$MD/app/Madeira/prefix-template.tar.gz" \
  "$MD/app/Madeira/arm64ec-windows/winemetal.dll" \
  "$MD/app/Madeira/vulkan/arm64ec-windows/winevulkan.dll" \
  "$MD/app/Madeira/vulkan/arm64ec-windows/vulkan-1.dll" \
  "$MD/app/Madeira/gl/libMoltenVK.dylib" \
  "$MD/app/Madeira/gl/libOSMesa.dylib"; do
  [[ -s "$file" ]] || { echo "ERROR: missing compiled native/PE component: $file" >&2; exit 2; }
done

if [[ "$GRAPHICS" == "d3d12" ]]; then
  for name in madeira_d3d12.dll d3d12.dll d3d12core.dll; do
    [[ -s "$MD/app/Madeira/arm64ec-windows/$name" ]] || {
      echo "ERROR: D3D12 build output missing: $name" >&2; exit 2;
    }
  done
fi

if [[ "${IDECK_BUILD_WOW64:-1}" == "1" ]]; then
  for name in aarch64-windows/xtajit.dll aarch64-windows/wow64.dll \
              aarch64-windows/wow64win.dll i386-windows/ntdll.dll \
              i386-windows/kernel32.dll i386-windows/user32.dll \
              i386-windows/d3d11.dll i386-windows/dxgi.dll; do
    [[ -s "$MD/app/Madeira/$name" ]] || {
      echo "ERROR: WoW64 requested, but missing $name" >&2; exit 2;
    }
  done
fi

python3 "$ROOT/scripts/verify_madeira_component_outputs.py" --root "$MD" --stage dxmt
echo "Madeira FEX/Wine ARM64EC/DXMT native inputs are present (graphics: $GRAPHICS)."
echo "Next: build the upstream host bridge and link the iDeck app."
