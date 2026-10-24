#!/usr/bin/env bash
set -euo pipefail
ROOT="${BITRISE_SOURCE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROOT="$(cd "$ROOT" && pwd)"
DEPLOY_DIR="${BITRISE_DEPLOY_DIR:?BITRISE_DEPLOY_DIR must be set by Bitrise}"
cd "$ROOT"

[[ "$(uname -s)" == "Darwin" ]] || { echo 'ERROR: Bitrise must use a macOS stack with Xcode.' >&2; exit 2; }
for tool in xcodebuild xcrun brew python3 git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing $tool" >&2; exit 2; }
done
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path
brew install cmake ninja meson bison pkg-config
export PATH="$(brew --prefix bison)/bin:$PATH"

if ! xcrun --sdk iphoneos --find metal >/dev/null 2>&1; then
  xcodebuild -downloadComponent MetalToolchain
fi
xcrun --sdk iphoneos --find metal >/dev/null

for path in scripts/fetch_madeira_sources.sh scripts/prepare_madeira_toolchains.sh scripts/build_native_runtime.sh scripts/build_madeira_components.sh scripts/link_madeira_native.sh scripts/build_ipa.sh scripts/verify_madeira_bundle.py; do
  [[ -f "$path" ]] || { echo "ERROR: required native-build script absent: $path" >&2; exit 2; }
done

if [[ "${IDECK_ACCEPT_METAL_CONVERTER_LICENSE:-0}" != "1" ]]; then
  echo 'ERROR: Metal Shader Converter distribution terms must be reviewed before setting IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1.' >&2
  exit 2
fi

bash scripts/fetch_madeira_sources.sh
bash scripts/prepare_madeira_toolchains.sh

rm -f "$ROOT/iDeck.ipa"
export IDECK_REQUIRE_MADEIRA=1
export IDECK_CONFIGURATION=Debug
bash scripts/build_native_runtime.sh

IPA="$ROOT/iDeck.ipa"
[[ -s "$IPA" ]] || { echo 'ERROR: native build did not generate iDeck.ipa.' >&2; exit 1; }

python3 - "$IPA" <<'PY'
import plistlib
import sys
from zipfile import ZipFile

ipa = sys.argv[1]
root = 'Payload/iDeck.app/'
required = (
    'iDeck',
    'Info.plist',
    'MadeiraRuntimeManifest.plist',
    'PlugIns/VPNExtension.appex/VPNExtension',
    'arm64ec-windows/xtajit64.dll',
    'arm64ec-windows/d3d12.dll',
    'arm64ec-windows/d3d12core.dll',
    'arm64ec-windows/winemetal.dll',
    'aarch64-windows/d3d11.dll',
    'aarch64-windows/dxgi.dll',
    'd3d12/libmetalirconverter.dylib',
    'prefix-template.tar.gz',
)
with ZipFile(ipa) as archive:
    names = set(archive.namelist())
    missing = [path for path in required if root + path not in names]
    if missing:
        raise SystemExit('ERROR: IPA missing Madeira components: ' + ', '.join(missing))
    corrupt = archive.testzip()
    if corrupt:
        raise SystemExit('ERROR: corrupt IPA entry: ' + corrupt)
    info = plistlib.loads(archive.read(root + 'Info.plist'))
    if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
        raise SystemExit('ERROR: not an iPhoneOS app')
    manifest = plistlib.loads(archive.read(root + 'MadeiraRuntimeManifest.plist'))
    for field in ('fexInProcess', 'wineInProcess', 'dxmtLinked', 'd3d12Linked'):
        if manifest.get(field) is not True:
            raise SystemExit('ERROR: native runtime manifest missing ' + field)
    for path in required:
        if path.endswith('.dll'):
            data = archive.read(root + path)
            if len(data) < 1024 or not data.startswith(b'MZ'):
                raise SystemExit('ERROR: invalid PE module ' + path)
print('Verified iPhoneOS IPA, native manifest, Windows PE modules and ZIP integrity.')
PY

mkdir -p "$DEPLOY_DIR"
cp "$IPA" "$DEPLOY_DIR/iDeck.ipa"
echo "Native iDeck IPA available: $DEPLOY_DIR/iDeck.ipa"
