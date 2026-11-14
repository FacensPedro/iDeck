#!/usr/bin/env bash
# Direct3D companion DLLs Wine has no implementation of, as stand-ins that answer
# "not available" (build/d3d-stubs): d3d11on12, d3d9on12, d3dcsx_42 and d3dcsx_43. A
# program that imports one of them could not start; with the stand-in it starts and
# takes its ordinary Direct3D path. Built for one architecture per call.
#
#   build_d3d_stub_dlls.sh <output folder> <i386|x86_64> [clang]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build/d3d-stubs"
OUT="${1:?Usage: build_d3d_stub_dlls.sh <output folder> <i386|x86_64> [clang]}"
ARCH="${2:?architecture: i386 or x86_64}"
case "$ARCH" in
  i386)   TRIPLE=i686-w64-mingw32;   ENTRY=_DllEntry@12; MACHINE=0x14C;  EXTRA=(-Wl,--kill-at) ;;
  x86_64) TRIPLE=x86_64-w64-mingw32; ENTRY=DllEntry;     MACHINE=0x8664; EXTRA=() ;;
  *) echo "ERROR: unknown architecture $ARCH" >&2; exit 2 ;;
esac
CC="${3:-$TRIPLE-clang}"
mkdir -p "$OUT"
FLAGS=(-shared -nostdlib -O2 "-Wl,--entry=$ENTRY" -Wl,--subsystem,windows "${EXTRA[@]}")
if [[ "$CC" != "$TRIPLE"-* ]]; then FLAGS+=("--target=${TRIPLE%-mingw32}-windows-gnu" -fuse-ld=lld); fi
build() { "$CC" "${FLAGS[@]}" -o "$OUT/$1.dll" "$ROOT/build/compat-dlls/entry.c" "$SRC/$2.c"; }
build d3d11on12 d3d11on12
build d3d9on12 d3d9on12
build d3dcsx_42 d3dcsx
build d3dcsx_43 d3dcsx
for name in d3d11on12 d3d9on12 d3dcsx_42 d3dcsx_43; do
  python3 - "$OUT/$name.dll" "$MACHINE" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", data, 0x3C)[0]
assert data[:2] == b"MZ" and data[pe:pe + 4] == b"PE\0\0", sys.argv[1]
assert struct.unpack_from("<H", data, pe + 4)[0] == int(sys.argv[2], 16), sys.argv[1] + " has the wrong machine type"
PY
done
echo "Direct3D stand-in DLLs ($ARCH) built into $OUT"
