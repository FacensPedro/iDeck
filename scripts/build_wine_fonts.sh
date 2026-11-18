#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
BUILD="$MD/wine/build-fonts"
OUT="$MD/app/Madeira/fonts"
export PATH="$MD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
command -v pkg-config >/dev/null
pkg-config --exists freetype2 || { echo "ERROR: host FreeType is required to build Wine bitmap fonts" >&2; exit 2; }
mkdir -p "$BUILD" "$OUT"
# A host-only tool build: the ARM64EC Wine tree deliberately disables FreeType.
# Keep its configure cache and target libraries independent from this converter.
if [[ ! -f "$BUILD/config.status" ]]; then
  (cd "$BUILD" && ../configure --enable-win64 --disable-tests --without-x --with-freetype)
fi
make -C "$BUILD" fonts/vgasys.fon fonts/vgafix.fon
# Wine's OEM font filename is referenced by win32u but has no make target.
# Generate the CP437 bitmap resource from Wine's own Fixedsys source.
"$BUILD/tools/sfnt2fon/sfnt2fon" -q -o "$BUILD/fonts/vgaoem.fon" \
  "$MD/wine/fonts/fixedsys.ttf" -d 128 15,437,8
cp "$MD/wine/fonts/"*.ttf "$OUT/"
for font in vgasys.fon vgafix.fon vgaoem.fon; do
  [[ -s "$BUILD/fonts/$font" ]] || { echo "ERROR: Wine bitmap font missing: $font" >&2; exit 2; }
  cp "$BUILD/fonts/$font" "$OUT/"
done
