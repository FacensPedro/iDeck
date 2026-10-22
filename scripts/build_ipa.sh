#!/bin/bash
# Builds an unsigned iDeck.ipa (sign it afterwards with AltStore, Sideloadly, etc.).
# Usage: scripts/build_ipa.sh   (needs macOS with Xcode)
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD_DIR="build"
rm -rf "$BUILD_DIR" Payload iDeck.ipa
mkdir -p "$BUILD_DIR"

xcodebuild clean build \
  -project iDeck.xcodeproj \
  -scheme iDeck \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

APP="$BUILD_DIR/Build/Products/Release-iphoneos/iDeck.app"
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }
[ -d "$APP/PlugIns/VPNExtension.appex" ] || { echo "error: VPNExtension.appex was not embedded" >&2; exit 1; }

mkdir -p Payload
cp -R "$APP" Payload/
zip -qry iDeck.ipa Payload
rm -rf Payload
echo "Created $(pwd)/iDeck.ipa"
