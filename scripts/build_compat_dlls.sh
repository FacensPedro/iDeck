#!/usr/bin/env bash
# Windows DLLs that Wine does not ship but programs load by name (build/compat-dlls):
# NTMARTA.dll and CLBCATQ.dll, both seen failing with STATUS_DLL_NOT_FOUND in 32-bit
# processes. Built as i386 PE into the WoW64 farm.
#
#   build_compat_dlls.sh <output folder> [clang]
# clang defaults to llvm-mingw's i686-w64-mingw32-clang; any clang that can target
# i686-w64-windows-gnu with lld works.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/build/compat-dlls"
OUT="${1:?Usage: build_compat_dlls.sh <output folder> [clang]}"
CC="${2:-i686-w64-mingw32-clang}"
mkdir -p "$OUT"
FLAGS=(-shared -nostdlib -O2 -Wl,--entry=_DllEntry@12 -Wl,--subsystem,windows)
if [[ "$CC" != i686-w64-mingw32-* ]]; then FLAGS+=(--target=i686-w64-windows-gnu -fuse-ld=lld); fi
"$CC" "${FLAGS[@]}" -o "$OUT/ntmarta.dll" "$SRC/entry.c" "$SRC/ntmarta.c"
"$CC" "${FLAGS[@]}" -o "$OUT/clbcatq.dll" "$SRC/entry.c" "$SRC/clbcatq.c" "$SRC/clbcatq.def"
for name in ntmarta clbcatq; do
  python3 - "$OUT/$name.dll" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
pe = struct.unpack_from("<I", data, 0x3C)[0]
assert data[:2] == b"MZ" and data[pe:pe + 4] == b"PE\0\0", sys.argv[1]
assert struct.unpack_from("<H", data, pe + 4)[0] == 0x14C, sys.argv[1] + " is not i386"
PY
done
echo "Compatibility DLLs built into $OUT: ntmarta.dll clbcatq.dll"
