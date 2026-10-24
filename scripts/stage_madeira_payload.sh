#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?Usage: stage_madeira_payload.sh /path/to/iDeck.app}"
SOURCE="${IDECK_MADEIRA_APP_ROOT:-$ROOT/vendor/Madeira/app/Madeira}"

[[ -d "$APP" ]] || { echo "iDeck .app not found: $APP" >&2; exit 2; }
[[ -d "$SOURCE" ]] || { echo "Madeira binary farm not found: $SOURCE" >&2; exit 2; }

OUT="$APP/MadeiraRuntime"
mkdir -p "$OUT"

for folder in aarch64-windows arm64ec-windows; do
    [[ -d "$SOURCE/$folder" ]] || { echo "Missing Wine PE farm: $SOURCE/$folder" >&2; exit 2; }
    cp -R "$SOURCE/$folder" "$OUT/$folder"
done

for path in aarch64-windows/d3d11.dll aarch64-windows/dxgi.dll arm64ec-windows/d3d12.dll arm64ec-windows/d3d12core.dll arm64ec-windows/xtajit64.dll; do
    [[ -s "$OUT/$path" ]] || { echo "Missing required Wine/DXMT/FEX file: $path" >&2; exit 2; }
    if [[ "$(head -c 2 "$OUT/$path")" != "MZ" ]]; then
        echo "Not a Windows PE binary: $path" >&2
        exit 2
    fi
done

mkdir -p "$OUT/d3d12"
for name in NOTICE.txt METAL-SHADER-CONVERTER-AGREEMENT.txt LICENSE-metal-shader-converter-headers.txt; do
    if [[ -f "$SOURCE/d3d12/$name" ]]; then cp "$SOURCE/d3d12/$name" "$OUT/d3d12/$name"; fi
done

if [[ "${IDECK_ACCEPT_METAL_CONVERTER_LICENSE:-0}" == "1" ]]; then
    [[ -s "$SOURCE/d3d12/libmetalirconverter.dylib" ]] || {
        echo "The licensed Metal Shader Converter dylib is missing." >&2
        exit 2
    }
    cp "$SOURCE/d3d12/libmetalirconverter.dylib" "$OUT/d3d12/libmetalirconverter.dylib"
else
    echo "Metal Shader Converter was NOT bundled: set IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 only after confirming redistribution rights." >&2
fi

echo "Staged Madeira Windows PE files in $OUT"
echo "This does NOT build or link native FEX/Wine/DXMT archives or sign the Metal converter."
