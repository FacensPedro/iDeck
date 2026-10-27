#!/bin/bash
# Builds an unsigned iDeck.ipa (sign it afterwards with AltStore, Sideloadly, etc.).
# Usage: scripts/build_ipa.sh   (needs macOS with Xcode)
set -euo pipefail

cd "$(dirname "$0")/.."
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
[[ "${SDK_VERSION%%.*}" -ge 27 ]] || { echo "ERROR: iDeck requires the iOS 27 SDK or newer." >&2; exit 2; }
BUILD_DIR="build"
rm -rf "$BUILD_DIR/Build" "$BUILD_DIR/Logs" Payload iDeck.ipa
mkdir -p "$BUILD_DIR"

EXTRA_XCODE_SETTINGS=()
CONFIGURATION="${IDECK_CONFIGURATION:-Release}"
NATIVE_ASSET_SOURCE=""
EXPORT_NATIVE_KIT=0
if [[ "${IDECK_REQUIRE_MADEIRA:-0}" == "1" ]]; then
  CONFIGURATION="${IDECK_CONFIGURATION:-Debug}"
  [[ "${IDECK_ACCEPT_METAL_CONVERTER_LICENSE:-0}" == "1" ]] || {
    echo "ERROR: Native build requires explicit Metal Shader Converter license/redistribution confirmation." >&2
    exit 2
  }
  KIT_FLAGS=()
  if [[ "${IDECK_BUILD_WOW64:-0}" == "1" ]]; then KIT_FLAGS+=(--wow64); fi
  if [[ "${IDECK_BUNDLE_WINE_MONO:-0}" == "1" ]]; then KIT_FLAGS+=(--mono); fi
  KIT_MODE="${IDECK_PREBUILT_MODE:-prefer}"
  [[ "$KIT_MODE" == "prefer" || "$KIT_MODE" == "only" || "$KIT_MODE" == "off" ]] || {
    echo "ERROR: IDECK_PREBUILT_MODE must be prefer, only or off." >&2
    exit 2
  }
  KIT_ARCHIVE=""
  if [[ "$KIT_MODE" != "off" ]]; then
    if [[ -n "${IDECK_PREBUILT_ARCHIVE:-}" ]]; then
      KIT_ARCHIVE="$IDECK_PREBUILT_ARCHIVE"
      [[ -s "$KIT_ARCHIVE" ]] || {
        echo "ERROR: explicit prebuilt Madeira kit not found: $KIT_ARCHIVE" >&2
        exit 2
      }
    else
      REPO_KIT="$(python3 scripts/madeira_native_kit.py path "${KIT_FLAGS[@]}")"
      CACHE_KIT="$(python3 scripts/madeira_native_kit.py path --cache "${KIT_FLAGS[@]}")"
      if [[ -s "$REPO_KIT" ]]; then
        KIT_ARCHIVE="$REPO_KIT"
      elif [[ -s "$CACHE_KIT" ]]; then
        KIT_ARCHIVE="$CACHE_KIT"
      fi
    fi
  fi
  if [[ -n "$KIT_ARCHIVE" ]]; then
    python3 scripts/madeira_native_kit.py install --archive "$KIT_ARCHIVE" "${KIT_FLAGS[@]}"
    NATIVE_ASSET_SOURCE="$(pwd)/build/madeira-prebuilt/resources"
    echo "Using precompiled Madeira FEX/Wine/DXMT/WineMetal/D3D12: $KIT_ARCHIVE"
  else
    if [[ "$KIT_MODE" == "only" ]]; then
      echo "ERROR: no matching prebuilt Madeira kit. Build once with IDECK_PREBUILT_MODE=off IDECK_PREBUILT_EXPORT=1." >&2
      exit 2
    fi
    bash scripts/build_madeira_components.sh
    bash scripts/link_madeira_native.sh
    NATIVE_ASSET_SOURCE="${IDECK_MADEIRA_ROOT:-$(pwd)/vendor/Madeira}/app/Madeira"
    if [[ "${IDECK_PREBUILT_EXPORT:-0}" == "1" ]]; then EXPORT_NATIVE_KIT=1; fi
  fi
  NATIVE_LINK_FLAGS="$(cat "$BUILD_DIR/madeira-native/link-flags.txt")"
  [[ -n "$NATIVE_LINK_FLAGS" ]] || { echo "ERROR: empty Madeira link flags" >&2; exit 2; }
  EXTRA_XCODE_SETTINGS+=(
    "IDECK_NATIVE_CFLAGS=-DIDECK_NATIVE_MADEIRA_ENABLED=1"
    "IDECK_NATIVE_LINK_FLAGS=$NATIVE_LINK_FLAGS"
  )
fi

xcodebuild clean build \
  -project iDeck.xcodeproj \
  -scheme iDeck \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  ${EXTRA_XCODE_SETTINGS[@]+"${EXTRA_XCODE_SETTINGS[@]}"}

APP="$BUILD_DIR/Build/Products/$CONFIGURATION-iphoneos/iDeck.app"
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }
for bundle in "$APP" "$APP/PlugIns/VPNExtension.appex"; do
  MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$bundle/Info.plist")"
  [[ "$MINIMUM_OS" == "27.0" ]] || { echo "ERROR: incorrect minimum OS in $bundle: $MINIMUM_OS" >&2; exit 2; }
done
[ -d "$APP/PlugIns/VPNExtension.appex" ] || { echo "error: VPNExtension.appex was not embedded" >&2; exit 1; }

if [ "${IDECK_REQUIRE_MADEIRA:-0}" = "1" ]; then
  IDECK_MADEIRA_APP_ROOT="$NATIVE_ASSET_SOURCE" \
    bash scripts/stage_madeira_payload.sh "$APP"
  WOW64_FLAGS=()
  if [[ "${IDECK_BUILD_WOW64:-0}" == "1" ]]; then
    WOW64_FLAGS+=(--require-wow64)
  fi
  python3 scripts/verify_madeira_bundle.py --app "$APP" --require "${WOW64_FLAGS[@]}"
  if [[ "$EXPORT_NATIVE_KIT" == "1" ]]; then
    python3 scripts/madeira_native_kit.py create --cache --resource-root "$APP" "${KIT_FLAGS[@]}"
  fi
else
  python3 scripts/verify_madeira_bundle.py --app "$APP"
fi

mkdir -p Payload
cp -R "$APP" Payload/
zip -qry iDeck.ipa Payload
if [[ "${IDECK_REQUIRE_MADEIRA:-0}" == "1" ]]; then
  python3 - <<'PY'
import stat
import zipfile

with zipfile.ZipFile("iDeck.ipa") as archive:
    links = [
        item.filename for item in archive.infolist()
        if item.filename.startswith("Payload/iDeck.app/MadeiraRuntime/")
        and stat.S_ISLNK(item.external_attr >> 16)
    ]
    if links:
        raise SystemExit("ERROR: Native IPA contains Unix symlinks unsupported by some Windows sideloaders: " + ", ".join(links))
    print("Native IPA runtime contains no Unix symlinks")
PY
fi
rm -rf Payload
echo "Created $(pwd)/iDeck.ipa"
