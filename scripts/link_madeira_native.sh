#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
OUT="$ROOT/build/madeira-native"
APP="$MD/app/Madeira"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

[[ "$(uname -s)" == "Darwin" ]] || { echo "ERROR: use a Mac with Xcode" >&2; exit 2; }
[[ "$ROOT" != *" "* ]] || { echo "ERROR: native linker paths must not contain spaces: $ROOT" >&2; exit 2; }
[[ -d "$MD/FEX/FEXCore/include" ]] || { echo "ERROR: Madeira FEX headers are absent." >&2; exit 2; }
mkdir -p "$OUT/obj"

FEX="$MD/FEX"
INCLUDES=(
  "-I$APP"
  "-I$MD/build"
  "-I$FEX/FEXCore/include"
  "-I$FEX/FEXHeaderUtils"
  "-I$FEX/CodeEmitter"
  "-I$FEX/External/fmt/include"
  "-I$FEX/External/range-v3/include"
  "-I$FEX/External/unordered_dense/include"
  "-I$FEX/build-ios"
  "-I$FEX/build-ios/include"
  "-I$FEX/build-ios/FEXCore/Source"
  "-I$FEX"
  "-I$MD/madeira-d3d12/third_party/metal-shader-converter/include"
)

SOURCES=(
  "JITAllocator.c"
  "FEXBridge.mm"
  "WineServerBridge.m"
  "WineProcessBridge.m"
  "PrefixExtractor.c"
  "IOSDisplayShim.m"
  "Winios/Winios.m"
  "Winios/WiniosGamepad.c"
  "Winios/WiniosCursor.c"
  "PadOutput.m"
  "wine_stubs.c"
)

OBJS=()
for entry in "${SOURCES[@]}"; do
  src="$APP/$entry"
  [[ -s "$src" ]] || { echo "ERROR: upstream Madeira bridge missing: $src" >&2; exit 2; }
  obj="$OUT/obj/${entry//\//_}.o"
  echo "Compiling upstream bridge: $entry"
  CMD=(xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=18.0 -O2 -fPIC
       -Wno-unused-parameter "${INCLUDES[@]}")
  if [[ "$entry" == *.m || "$entry" == *.mm ]]; then
    CMD+=(-fobjc-arc)
  fi
  if [[ "$entry" == *.mm ]]; then
    CMD+=(-std=c++20 -fexceptions -frtti)
  fi
  "${CMD[@]}" -c "$src" -o "$obj"
  OBJS+=("$obj")
done

# The pinned Madeira DXMT archive already contains msc_canary.o, including
# madeira_d3d12_canary_run and madeira_d3d12_canary_run_log.
# Never recompile it into the forced-load iDeck bridge archive: doing so
# duplicates both globally exported symbols in the final Mach-O link.
#
# Madeira's libwineserver.a likewise owns wine_ui_log / its callback setter.
# Do not build iDeck/NativeRuntime/MadeiraHostCallbacks.m into this archive;
# that file defines another wine_ui_log and collides with wine_log_ios.o.
xcrun --sdk iphoneos ar rcs "$OUT/libideck_madeira_upstream_bridges.a" "${OBJS[@]}"
xcrun --sdk iphoneos ranlib "$OUT/libideck_madeira_upstream_bridges.a"

ARCHIVES=(
  "$OUT/libideck_madeira_upstream_bridges.a"
  "$MD/FEX/build-ios/FEXCore/Source/libFEXCore.a"
  "$MD/FEX/build-ios/FEXCore/Source/libFEXCore_Base.a"
  "$MD/FEX/build-ios/FEXCore/Source/libJemallocLibs.a"
  "$MD/FEX/build-ios/External/fmt/libfmt.a"
  "$MD/FEX/build-ios/External/cephes/libcephes_128bit.a"
  "$MD/FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a"
  "$MD/FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a"
  "$APP/libwineserver.a"
  "$APP/libntdll_unix.a"
  "$APP/libwin32u_unix.a"
  "$APP/libdxmt_combined.a"
  "$APP/libgnutls.a"
  "$APP/libhogweed.a"
  "$APP/libnettle.a"
  "$APP/libgmp.a"
  "$APP/libavformat.a"
  "$APP/libavcodec.a"
  "$APP/libswresample.a"
  "$APP/libavutil.a"
)

for file in "${ARCHIVES[@]}"; do
  [[ -s "$file" ]] || { echo "ERROR: native archive missing: $file" >&2; exit 2; }
  archs="$(xcrun lipo -archs "$file" 2>/dev/null)" || {
    echo "ERROR: not a valid iOS static archive: $file" >&2
    exit 2
  }
  [[ " $archs " == *" arm64 "* ]] || { echo "ERROR: archive does not contain arm64: $file ($archs)" >&2; exit 2; }
done

# The D3D12 diagnostic ABI must be provided by the single DXMT archive.
# Checking now prevents an invalid duplicate or a missing symbol from reaching
# the much slower Xcode link. nm -gU reports defined external Mach-O symbols.
if ! xcrun --sdk iphoneos nm -gU "$APP/libdxmt_combined.a" | awk '
  $NF == "_madeira_d3d12_canary_run" { run = 1 }
  $NF == "_madeira_d3d12_canary_run_log" { log = 1 }
  END { if (!(run && log)) exit 1 }
'; then
  echo "ERROR: the native DXMT archive must export both D3D12 canary entry points." >&2
  exit 2
fi

# Report the remaining strong-symbol overlaps before the Xcode link. This
# analysis is diagnostic: a member that is never extracted from its archive
# cannot actually collide, so reporting a candidate must not break the build.
python3 "$ROOT/scripts/report_madeira_symbol_collisions.py" \
  "$OUT/libideck_madeira_upstream_bridges.a" \
  "$APP/libwineserver.a" "$APP/libntdll_unix.a" \
  "$APP/libwin32u_unix.a" "$APP/libdxmt_combined.a" || true

FLAGS=( -lz -lc++ -lsqlite3 -llzma
  -framework Metal -framework MetalFX -framework QuartzCore -framework AVFoundation
  -framework AudioToolbox -framework VideoToolbox -framework CoreMedia
  -framework CoreVideo -framework CoreFoundation -framework IOKit
  -framework ImageIO -framework GameController -framework CoreHaptics
)
FLAGS+=(-force_load "${ARCHIVES[0]}" -force_load "${ARCHIVES[11]}")
for index in "${!ARCHIVES[@]}"; do
  if ((index == 0 || index == 11)); then continue; fi
  FLAGS+=("${ARCHIVES[$index]}")
done

# The cross-built LLVM archives bundled into DXMT depend on the iPhoneOS
# terminfo (libcurses) and libxml2 SDK libraries. Keep these link inputs
# after the native static archives so their undefined symbols are resolved.
FLAGS+=(-lcurses -lxml2)

printf '%s ' "${FLAGS[@]}" > "$OUT/link-flags.txt"
echo >> "$OUT/link-flags.txt"
echo "Prepared actual arm64 upstream native bridge and link flags: $OUT/link-flags.txt"
