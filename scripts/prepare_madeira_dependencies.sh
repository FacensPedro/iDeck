#!/usr/bin/env bash
set -euo pipefail

MD="${1:?Usage: prepare_madeira_dependencies.sh MADEIRA_ROOT}"

require_files() {
  local file
  for file in "$@"; do
    [[ -s "$file" ]] || return 1
  done
}

# Shipped app archives do not include the development headers needed to
# rebuild the Unix libraries. Install headers and matching archives together.
GNUTLS="$MD/toolchains/gnutls-ios"
GNUTLS_FILES=("$GNUTLS/include/gnutls/gnutls.h" "$GNUTLS/include/gnutls/pkcs12.h")
for lib in gmp nettle hogweed gnutls; do
  GNUTLS_FILES+=("$GNUTLS/lib/lib$lib.a")
done
if ! require_files "${GNUTLS_FILES[@]}"; then
  # An interrupted install must not be hidden by upstream stage markers.
  rm -f "$MD/build/gnutls-ios/obj/"{gmp,nettle,gnutls}.done
  (cd "$MD/build/gnutls-ios/src" && shasum -a 256 -c SHA256SUMS)
  bash "$MD/build/gnutls-ios/build.sh"
fi
require_files "${GNUTLS_FILES[@]}" || { echo 'ERROR: GnuTLS development files missing after build.' >&2; exit 2; }
for lib in gmp nettle hogweed gnutls; do
  cp "$GNUTLS/lib/lib$lib.a" "$MD/app/Madeira/lib$lib.a"
done

FFMPEG="$MD/toolchains/ffmpeg-ios"
FFMPEG_FILES=()
for lib in avformat avcodec swresample avutil; do
  FFMPEG_FILES+=("$FFMPEG/include/lib$lib/$lib.h" "$FFMPEG/lib/lib$lib.a")
done
if ! require_files "${FFMPEG_FILES[@]}"; then
  bash "$MD/build/ffmpeg/build.sh"
fi
require_files "${FFMPEG_FILES[@]}" || { echo 'ERROR: FFmpeg development files missing after build.' >&2; exit 2; }
for lib in avformat avcodec swresample avutil; do
  cp "$FFMPEG/lib/lib$lib.a" "$MD/app/Madeira/lib$lib.a"
done

# Madeira's FreeType builder expects this source tree but does not fetch it.
# Pin the commit behind upstream's documented FreeType 2.13.3 release.
FREETYPE="$MD/research/freetype"
FREETYPE_REV=42608f77f20749dd6ddc9e0536788eaad70ea4b5
if [[ ! -d "$FREETYPE/.git" ]]; then
  git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git "$FREETYPE"
fi
[[ "$(git -C "$FREETYPE" rev-parse HEAD)" == "$FREETYPE_REV" ]] || {
  echo "ERROR: FreeType must be at $FREETYPE_REV." >&2; exit 2;
}
bash "$MD/build/freetype-ios/build.sh"
require_files "$FREETYPE/include/ft2build.h" "$MD/build/freetype-ios/build/libfreetype.a" || {
  echo 'ERROR: FreeType development files missing after build.' >&2; exit 2;
}
