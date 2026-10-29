#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
MINGW="$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
SRC="$MD/research/LuaJIT"
REV="a4c064539ea931274d407e1249b4bb575424a0f4"
OUT="$MD/app/Madeira/compat/love"
[[ -x "$MINGW/x86_64-w64-mingw32-strip" ]] || {
  echo "ERROR: verified x86_64 LLVM-MinGW toolchain not available" >&2
  exit 2
}
if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "$(dirname "$SRC")"
  git clone --filter=blob:none https://github.com/LuaJIT/LuaJIT.git "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$REV"
git -C "$SRC" checkout --detach "$REV"
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$REV" ]] || {
  echo "ERROR: LuaJIT source revision mismatch" >&2
  exit 2
}
export PATH="$MINGW:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
make -C "$SRC/src" clean >/dev/null
make -C "$SRC/src" -j"$(sysctl -n hw.ncpu)" \
  HOST_CC="xcrun clang" \
  CROSS=x86_64-w64-mingw32- \
  TARGET_SYS=Windows \
  BUILDMODE=dynamic \
  XCFLAGS="-DLUAJIT_DISABLE_JIT -DLUAJIT_NO_UNWIND" lua51.dll
mkdir -p "$OUT" "$MD/app/Madeira/licenses"
"$MINGW/x86_64-w64-mingw32-strip" -o "$OUT/lua51.dll" "$SRC/src/lua51.dll"
[[ "$(head -c 2 "$OUT/lua51.dll")" == "MZ" ]] || {
  echo "ERROR: GC64 LuaJIT is not a Windows x64 PE" >&2
  exit 2
}
printf '%s\n' "$REV" > "$OUT/lua51.dll.version"
cp "$SRC/COPYRIGHT" "$MD/app/Madeira/licenses/LuaJIT-MIT.txt"
echo "GC64 LuaJIT compatibility DLL: $OUT/lua51.dll"
