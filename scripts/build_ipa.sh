#!/bin/bash
# Builds an unsigned iDeck.ipa (sign it afterwards with AltStore, Sideloadly, etc.).
# Usage: scripts/build_ipa.sh   (needs macOS with Xcode)
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD_DIR="build"
rm -rf "$BUILD_DIR/Build" "$BUILD_DIR/Logs" Payload iDeck.ipa
mkdir -p "$BUILD_DIR"

EXTRA_XCODE_SETTINGS=()
CONFIGURATION="${IDECK_CONFIGURATION:-Release}"
if [ "${IDECK_REQUIRE_MADEIRA:-0}" = "1" ]; then
  CONFIGURATION="${IDECK_CONFIGURATION:-Debug}"
  bash scripts/build_madeira_components.sh
  bash scripts/link_madeira_native.sh
  NATIVE_LINK_FLAGS="$(cat "$BUILD_DIR/madeira-native/link-flags.txt")"
  [[ -n "$NATIVE_LINK_FLAGS" ]] || { echo "Missing Madeira linker flags" >&2; exit 2; }
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
[ -d "$APP/PlugIns/VPNExtension.appex" ] || { echo "error: VPNExtension.appex was not embedded" >&2; exit 1; }

if [ "${IDECK_REQUIRE_MADEIRA:-0}" = "1" ]; then
  IDECK_MADEIRA_APP_ROOT="${IDECK_MADEIRA_ROOT:-$(pwd)/vendor/Madeira}/app/Madeira" \
    bash scripts/stage_madeira_payload.sh "$APP"
  python3 scripts/verify_madeira_bundle.py --app "$APP" --require
else
  python3 scripts/verify_madeira_bundle.py --app "$APP"
fi

mkdir -p Payload
cp -R "$APP" Payload/
zip -qry iDeck.ipa Payload
rm -rf Payload
echo "Created $(pwd)/iDeck.ipa"
