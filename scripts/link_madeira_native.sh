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

CANARY_SRC="$MD/madeira-d3d12/tests/native/msc_canary.mm"
[[ -s "$CANARY_SRC" ]] || { echo "ERROR: upstream D3D12 canary source missing: $CANARY_SRC" >&2; exit 2; }
CANARY_OBJ="$OUT/obj/msc_canary.o"
echo "Compiling upstream D3D12 Metal Shader Converter canary"
xcrun --sdk iphoneos clang++ -arch arm64 -isysroot "$SDK" -miphoneos-version-min=18.0 \
  -O2 -fPIC -fobjc-arc -std=c++20 -fexceptions -frtti \
  "${INCLUDES[@]}" -c "$CANARY_SRC" -o "$CANARY_OBJ"
OBJS+=("$CANARY_OBJ")

echo "Compiling iDeck host log callbacks"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=18.0 -O2 \
  -fobjc-arc -c "$ROOT/iDeck/NativeRuntime/MadeiraHostCallbacks.m" \
  -o "$OUT/obj/MadeiraHostCallbacks.o"
OBJS+=("$OUT/obj/MadeiraHostCallbacks.o")
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

printf '%s ' "${FLAGS[@]}" > "$OUT/link-flags.txt"
echo >> "$OUT/link-flags.txt"
echo "Prepared actual arm64 upstream native bridge and link flags: $OUT/link-flags.txt"
