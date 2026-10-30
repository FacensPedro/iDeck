#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
LLVM_REF="${IDECK_LLVM_REF:-llvmorg-15.0.7}"
SDK="$MD/toolchains/llvm-ios-build"
MINGW="$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/arm64ec-w64-mingw32-clang"
REQUIRE_DEPS=0

if [[ "${1:-}" == "--require-deps" ]]; then
  REQUIRE_DEPS=1
  shift
fi
[[ $# -eq 0 ]] || { echo "ERROR: unexpected toolchain verifier arguments." >&2; exit 2; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "ERROR: macOS/Xcode required." >&2; exit 2; }
[[ -x "$MINGW" ]] || { echo "ERROR: exact pinned ARM64EC llvm-mingw compiler missing: $MINGW" >&2; exit 2; }
python3 "$ROOT/scripts/llvm_ios_sdk.py" check --build "$SDK" --ref "$LLVM_REF"
bash "$ROOT/scripts/verify_dxmt_llvm.sh"

TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ideck-toolchain-verification.XXXXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
printf 'int ideck_arm64ec_probe(void) { return 42; }\n' > "$TEMP/probe.c"
"$MINGW" -x c -c "$TEMP/probe.c" -o "$TEMP/arm64ec.o"
python3 - "$TEMP/arm64ec.o" <<'PY'
import struct
import sys
from pathlib import Path
file = Path(sys.argv[1])
data = file.read_bytes()
if len(data) < 20 or struct.unpack_from("<H", data, 0)[0] != 0xA641:
    raise SystemExit("ERROR: ARM64EC clang did not generate ARM64EC COFF (machine 0xA641)")
print("Verified real ARM64EC COFF object emitted by llvm-mingw.")
PY

check_ios_archive() {
  local path="$1"
  [[ -s "$path" ]] || { echo "ERROR: missing real iOS archive: $path" >&2; exit 2; }
  local arches
  arches="$(xcrun lipo -archs "$path")" || {
    echo "ERROR: unreadable Mach-O static archive: $path" >&2
    exit 2
  }
  [[ "$arches" == "arm64" ]] || {
    echo "ERROR: non-iPhoneOS arm64 or mixed architecture in $path: $arches" >&2
    exit 2
  }
}

for lib in LLVMCore LLVMSupport LLVMBitReader LLVMBitWriter; do
  check_ios_archive "$SDK/lib/lib$lib.a"
done

if [[ "$REQUIRE_DEPS" == "1" ]]; then
  for name in gnutls gmp nettle hogweed; do
    check_ios_archive "$MD/toolchains/gnutls-ios/lib/lib$name.a"
  done
  for name in avformat avcodec swresample avutil; do
    check_ios_archive "$MD/toolchains/ffmpeg-ios/lib/lib$name.a"
  done
  check_ios_archive "$MD/build/freetype-ios/build/libfreetype.a"
  for header in \
    "$MD/toolchains/gnutls-ios/include/gnutls/gnutls.h" \
    "$MD/toolchains/ffmpeg-ios/include/libavcodec/avcodec.h" \
    "$MD/research/freetype/include/ft2build.h"; do
    [[ -s "$header" ]] || { echo "ERROR: missing dependency header: $header" >&2; exit 2; }
  done
fi

echo "PASS: pinned public ARM64EC compiler and iPhoneOS arm64 LLVM archives verified (dependencies=$REQUIRE_DEPS)."
