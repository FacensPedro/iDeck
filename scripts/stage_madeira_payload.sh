#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?Usage: stage_madeira_payload.sh /path/to/iDeck.app}"
SOURCE="${IDECK_MADEIRA_APP_ROOT:-$ROOT/vendor/Madeira/app/Madeira}"

[[ -d "$APP" ]] || { echo "ERROR: missing iDeck.app: $APP" >&2; exit 2; }
[[ -d "$SOURCE" ]] || { echo "ERROR: Madeira compiled resources missing: $SOURCE" >&2; exit 2; }

RUNTIME="$APP/MadeiraRuntime"
mkdir -p "$RUNTIME"

# The upstream Madeira bridge uses NSBundle.mainBundle for these paths.
# They must exist at the top level, not only under MadeiraRuntime.
for folder in aarch64-windows arm64ec-windows nls; do
  [[ -d "$SOURCE/$folder" ]] || { echo "ERROR: missing Madeira asset folder: $folder" >&2; exit 2; }
  cp -R "$SOURCE/$folder" "$APP/$folder"
done

[[ -s "$SOURCE/prefix-template.tar.gz" ]] || {
  echo "ERROR: missing Wine prefix-template.tar.gz" >&2; exit 2;
}
cp "$SOURCE/prefix-template.tar.gz" "$APP/prefix-template.tar.gz"
[[ "$(od -An -tx1 -N2 "$APP/prefix-template.tar.gz" | tr -d '[:space:]')" == "1f8b" ]] || {
  echo "ERROR: invalid Wine prefix archive gzip header" >&2; exit 2;
}

for path in aarch64-windows/d3d11.dll aarch64-windows/dxgi.dll \
            aarch64-windows/winemetal.dll arm64ec-windows/ntdll.dll \
            arm64ec-windows/d3d11.dll arm64ec-windows/dxgi.dll \
            arm64ec-windows/d3d10core.dll \
            arm64ec-windows/d3d12.dll arm64ec-windows/d3d12core.dll \
            arm64ec-windows/xtajit64.dll arm64ec-windows/winemetal.dll; do
  FILE="$APP/$path"
  [[ -s "$FILE" ]] || { echo "ERROR: missing PE module: $path" >&2; exit 2; }
  [[ "$(head -c 2 "$FILE")" == "MZ" ]] || {
    echo "ERROR: not a Windows PE module: $path" >&2; exit 2;
  }
done

for folder in aarch64-windows arm64ec-windows; do
  ln -s "../$folder" "$RUNTIME/$folder"
done

mkdir -p "$APP/d3d12" "$RUNTIME/d3d12"
for name in NOTICE.txt METAL-SHADER-CONVERTER-AGREEMENT.txt LICENSE-metal-shader-converter-headers.txt; do
  [[ -f "$SOURCE/d3d12/$name" ]] || { echo "ERROR: missing converter legal notice: $name" >&2; exit 2; }
  cp "$SOURCE/d3d12/$name" "$APP/d3d12/$name"
  cp "$SOURCE/d3d12/$name" "$RUNTIME/d3d12/$name"
done

[[ "${IDECK_ACCEPT_METAL_CONVERTER_LICENSE:-0}" == "1" ]] || {
  echo "ERROR: Metal Shader Converter redistribution rights not confirmed." >&2
  echo "Set IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 after reviewing the upstream Apple agreement." >&2
  exit 2
}
[[ -s "$SOURCE/d3d12/libmetalirconverter.dylib" ]] || {
  echo "ERROR: licensed Metal Shader Converter iOS dylib not available." >&2
  exit 2
}
cp "$SOURCE/d3d12/libmetalirconverter.dylib" "$APP/d3d12/libmetalirconverter.dylib"
ln -s "../../d3d12/libmetalirconverter.dylib" "$RUNTIME/d3d12/libmetalirconverter.dylib"

# Dynamic code must be signed by the same signing workflow as the host IPA.
# An ad hoc signature alone is not a distribution/developer identity.
if [[ -n "${IDECK_CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$IDECK_CODESIGN_IDENTITY" --timestamp=none \
    "$APP/d3d12/libmetalirconverter.dylib"
fi

echo "Madeira Wine/DXMT/D3D12 resources staged under iDeck.app."
echo "Native libraries must also be linked and the final app must be signed and device-tested."
