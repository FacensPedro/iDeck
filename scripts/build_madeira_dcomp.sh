#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
MINGW="$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
SOURCE="$ROOT/build/dcomp"
OUTPUT="$ROOT/build/madeira-dcomp/dcomp.dll"
DEST="$MD/app/Madeira/arm64ec-windows/dcomp.dll"

[[ -x "$MINGW/arm64ec-w64-mingw32-clang" && -x "$MINGW/llvm-readobj" ]] || {
  echo "ERROR: verified ARM64EC LLVM-MinGW toolchain is required" >&2
  exit 2
}
[[ -s "$SOURCE/dcomp.c" && -s "$SOURCE/dcomp.def" ]] || {
  echo "ERROR: version-pinned Madeira DirectComposition sources are missing" >&2
  exit 2
}
mkdir -p "$(dirname "$OUTPUT")" "$(dirname "$DEST")"
"$MINGW/arm64ec-w64-mingw32-clang" -shared -O2 -Wall \
  -o "$OUTPUT" "$SOURCE/dcomp.c" "$SOURCE/dcomp.def"
expected="$(awk 'in_exports && NF { print $1 } /^EXPORTS/ { in_exports = 1 }' "$SOURCE/dcomp.def" | sort)"
actual="$("$MINGW/llvm-readobj" --coff-exports "$OUTPUT" | awk '$1 == "Name:" { print $2 }' | sort)"
if [[ -z "$expected" || "$expected" != "$actual" ]]; then
  echo "ERROR: compiled DirectComposition export list differs from pinned upstream definitions" >&2
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
  exit 2
fi
[[ "$(head -c 2 "$OUTPUT")" == "MZ" ]] || {
  echo "ERROR: generated dcomp.dll is not a Windows PE module" >&2
  exit 2
}
cp "$OUTPUT" "$DEST"
cmp -s "$OUTPUT" "$DEST"
echo "Compiled updated ARM64EC DirectComposition: $DEST"
