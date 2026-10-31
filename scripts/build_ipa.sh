#!/bin/bash
# Builds an unsigned iDeck.ipa (sign it afterwards with AltStore, Sideloadly, etc.).
# Usage: scripts/build_ipa.sh   (needs macOS with Xcode)
set -euo pipefail

cd "$(dirname "$0")/.."
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
[[ "${SDK_VERSION%%.*}" -ge 27 ]] || { echo "ERROR: iDeck requires the iOS 27 SDK or newer." >&2; exit 2; }
if [[ "${IDECK_REQUIRE_IPHONE_DUO_SDK:-0}" == "1" ]]; then
  SDK_MAJOR="${SDK_VERSION%%.*}"
  SDK_MINOR="${SDK_VERSION#*.}"
  [[ "$SDK_MINOR" == "$SDK_VERSION" ]] && SDK_MINOR=0
  SDK_MINOR="${SDK_MINOR%%.*}"
  if (( SDK_MAJOR < 27 || (SDK_MAJOR == 27 && SDK_MINOR < 1) )); then
    echo "ERROR: iPhone Duo full-display layout requires Xcode with the iOS 27.1 SDK or newer." >&2
    exit 2
  fi
fi
BUILD_DIR="build"
# Keep restored Xcode intermediates and products; the ephemeral Actions runner
# starts clean unless its exact-revision cache was restored.
rm -rf "$BUILD_DIR/Logs" "$BUILD_DIR/Staging" Payload iDeck.ipa
mkdir -p "$BUILD_DIR"

EXTRA_XCODE_SETTINGS=()
CONFIGURATION="${IDECK_CONFIGURATION:-Release}"
NATIVE_ASSET_SOURCE=""
EXPORT_NATIVE_KIT=0
if [[ "${IDECK_REQUIRE_MADEIRA:-0}" == "1" ]]; then
  CONFIGURATION="${IDECK_CONFIGURATION:-Debug}"
  export IDECK_MADEIRA_GRAPHICS="${IDECK_MADEIRA_GRAPHICS:-d3d12}"
  [[ "$IDECK_MADEIRA_GRAPHICS" == "d3d11" || "$IDECK_MADEIRA_GRAPHICS" == "d3d12" ]] || {
    echo "ERROR: IDECK_MADEIRA_GRAPHICS must be d3d11 or d3d12." >&2; exit 2;
  }
  if [[ "$IDECK_MADEIRA_GRAPHICS" == "d3d12" ]]; then
    [[ "${IDECK_ACCEPT_METAL_CONVERTER_LICENSE:-0}" == "1" ]] || {
      echo "ERROR: Native D3D12 build requires explicit converter distribution permission." >&2
      exit 2
    }
  fi
  # Full Wine/FEX i386 support is the default for native IPA builds.
  # Explicit IDECK_BUILD_WOW64=0 retains the smaller x64-only profile.
  export IDECK_BUILD_WOW64="${IDECK_BUILD_WOW64:-1}"
  [[ "$IDECK_BUILD_WOW64" == "0" || "$IDECK_BUILD_WOW64" == "1" ]] || {
    echo "ERROR: IDECK_BUILD_WOW64 must be 0 or 1." >&2
    exit 2
  }
  if [[ -n "${IDECK_MSC_PKG:-}" ]]; then
    [[ "$IDECK_MADEIRA_GRAPHICS" == "d3d12" ]] || {
      echo "ERROR: Apple Metal Shader Converter package is for an explicitly selected D3D12 build." >&2
      exit 2
    }
    export IDECK_PREBUILT_MODE=off
    export IDECK_MSC_REQUIRE_BETA3=1
    MSC_ROOT="${IDECK_MADEIRA_ROOT:-$(pwd)/vendor/Madeira}"
    if [[ ! -f "$MSC_ROOT/app/Madeira/FEXBridge.mm" ]]; then
      bash scripts/fetch_madeira_sources.sh
    fi
    python3 scripts/prepare_apple_msc_beta3.py \
      --pkg "$IDECK_MSC_PKG" \
      --destination "$MSC_ROOT/app/Madeira/d3d12" \
      --headers-destination "$MSC_ROOT/madeira-d3d12/third_party/metal-shader-converter/include" \
      --acknowledge-license
  fi
  KIT_FLAGS=(--graphics "$IDECK_MADEIRA_GRAPHICS")
  if [[ "$IDECK_BUILD_WOW64" == "1" ]]; then KIT_FLAGS+=(--wow64); fi
  if [[ "${IDECK_BUNDLE_WINE_MONO:-0}" == "1" ]]; then KIT_FLAGS+=(--mono); fi
  # Both graphics profiles have distinct, strictly validated native kit formats.
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
      REPO_KIT="$(python3 scripts/madeira_native_kit.py path ${KIT_FLAGS[@]+"${KIT_FLAGS[@]}"})"
      CACHE_KIT="$(python3 scripts/madeira_native_kit.py path --cache ${KIT_FLAGS[@]+"${KIT_FLAGS[@]}"})"
      # Prefer the repository archive when valid, but never load an old
      # FEX/Wine binary that predates the required ARM64EC Mach context patch.
      for CANDIDATE in "$REPO_KIT" "$CACHE_KIT"; do
        if [[ -s "$CANDIDATE" ]] &&
           python3 scripts/madeira_native_kit.py inspect --archive "$CANDIDATE" ${KIT_FLAGS[@]+"${KIT_FLAGS[@]}"} >/dev/null 2>&1; then
          KIT_ARCHIVE="$CANDIDATE"
          break
        fi
      done
    fi
  fi
  if [[ -n "$KIT_ARCHIVE" ]] &&
     ! python3 scripts/madeira_native_kit.py inspect --archive "$KIT_ARCHIVE" ${KIT_FLAGS[@]+"${KIT_FLAGS[@]}"}; then
    echo "ERROR: Selected Madeira kit predates the ARM64EC Mach-context fix. Build from sources." >&2
    exit 2
  fi
  if [[ -n "$KIT_ARCHIVE" ]]; then
    python3 scripts/madeira_native_kit.py install --archive "$KIT_ARCHIVE" ${KIT_FLAGS[@]+"${KIT_FLAGS[@]}"}
    NATIVE_ASSET_SOURCE="$(pwd)/build/madeira-prebuilt/resources"
    echo "Using verified Madeira native runtime profile=$IDECK_MADEIRA_GRAPHICS: $KIT_ARCHIVE"
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
  # Apply to both source builds and imported kits: dlsym entry points must
  # survive Release dead stripping and be visible in the dynamic symbol table.
  NATIVE_LINK_FLAGS+=" $(python3 scripts/verify_madeira_bundle.py --linker-flags --graphics "$IDECK_MADEIRA_GRAPHICS")"
  EXTRA_XCODE_SETTINGS+=(
    "IDECK_NATIVE_CFLAGS=-DIDECK_NATIVE_MADEIRA_ENABLED=1 -DIDECK_MADEIRA_D3D12_ENABLED=$([[ "$IDECK_MADEIRA_GRAPHICS" == "d3d12" ]] && echo 1 || echo 0)"
    "IDECK_NATIVE_LINK_FLAGS=$NATIVE_LINK_FLAGS"
  )
fi

xcodebuild build \
  -project iDeck.xcodeproj \
  -scheme iDeck \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  ${EXTRA_XCODE_SETTINGS[@]+"${EXTRA_XCODE_SETTINGS[@]}"}

COMPILED_APP="$BUILD_DIR/Build/Products/$CONFIGURATION-iphoneos/iDeck.app"
[ -d "$COMPILED_APP" ] || { echo "error: $COMPILED_APP not found" >&2; exit 1; }
APP="$COMPILED_APP"
if [[ "${IDECK_REQUIRE_MADEIRA:-0}" == "1" ]]; then
  # Stage licensed native payload into a separate app copy, never into
  # Xcode's cached product. That keeps incremental relinks trustworthy.
  APP="$BUILD_DIR/Staging/iDeck.app"
  mkdir -p "$BUILD_DIR/Staging"
  ditto "$COMPILED_APP" "$APP"
fi
for bundle in "$APP" "$APP/PlugIns/VPNExtension.appex"; do
  MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$bundle/Info.plist")"
  [[ "$MINIMUM_OS" == "26.0" ]] || { echo "ERROR: incorrect minimum OS in $bundle: $MINIMUM_OS" >&2; exit 2; }
done
[ -d "$APP/PlugIns/VPNExtension.appex" ] || { echo "error: VPNExtension.appex was not embedded" >&2; exit 1; }
# Verify the unsigned bundle IDs before packaging. Sideloaders may rewrite IDs
# while signing, so these checks intentionally run before external resigning.
for spec in "$APP:com.ideck.ideck" "$APP/PlugIns/VPNExtension.appex:com.ideck.ideck.VPNExtension"; do
  BUNDLE="${spec%%:*}"
  EXPECTED="${spec#*:}"
  ACTUAL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUNDLE/Info.plist")"
  [[ "$ACTUAL" == "$EXPECTED" ]] || {
    echo "ERROR: unexpected bundle ID in $BUNDLE: expected $EXPECTED, got $ACTUAL" >&2
    exit 2
  }
done


if [ "${IDECK_REQUIRE_MADEIRA:-0}" = "1" ]; then
  IDECK_MADEIRA_APP_ROOT="$NATIVE_ASSET_SOURCE" \
    bash scripts/stage_madeira_payload.sh "$APP"
  # Native builds use the Debug configuration (upstream Madeira's guest code
  # is unreliable in Release). Drop only the debugger's STABS debug map from
  # the executables: exported and global symbols stay for dlsym and crash logs.
  for image in "$APP/iDeck" "$APP/iDeck.debug.dylib"; do
    [[ -f "$image" ]] && xcrun strip -S "$image"
  done
  if [[ "${IDECK_BUILD_WOW64:-0}" == "1" ]]; then
    python3 scripts/verify_madeira_bundle.py --app "$APP" --require --require-wow64 --graphics "$IDECK_MADEIRA_GRAPHICS"
  else
    python3 scripts/verify_madeira_bundle.py --app "$APP" --require --graphics "$IDECK_MADEIRA_GRAPHICS"
  fi
  python3 scripts/verify_madeira_legal_notices.py --app "$APP" --graphics "$IDECK_MADEIRA_GRAPHICS"
  if [[ "$EXPORT_NATIVE_KIT" == "1" ]]; then
    python3 scripts/madeira_native_kit.py create --cache --resource-root "$APP" ${KIT_FLAGS[@]+"${KIT_FLAGS[@]}"}
  fi
else
  python3 scripts/verify_madeira_bundle.py --app "$APP"
fi

# Stamp the observed IPA profile only after the strict native bundle
# verifier passes; a PR/interface build cannot claim a native Wine runtime.
PROFILE_ARGS=()
if [[ "${IDECK_REQUIRE_MADEIRA:-0}" == "1" ]]; then
  PROFILE_ARGS+=(--require-native --expected-graphics "$IDECK_MADEIRA_GRAPHICS")
fi
python3 scripts/stamp_ideck_runtime_profile.py --app "$APP" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"}

# Stream the app directly into a valid IPA, with fast compression and
# symlink/executable-bit preservation; do not duplicate the native app as
# a temporary Payload tree or recompress PNG/ZIP/GZ assets.
python3 scripts/package_ipa.py --app "$APP" --output iDeck.ipa
if [[ "${IDECK_REQUIRE_MADEIRA:-0}" == "1" && "${IDECK_MADEIRA_GRAPHICS:-d3d11}" == "d3d12" && -n "${IDECK_MSC_PKG:-}" ]]; then
  python3 scripts/verify_apple_msc_beta3_bundle.py \
    --source "${IDECK_MADEIRA_ROOT:-$(pwd)/vendor/Madeira}/app/Madeira" \
    --app "$APP" \
    --ipa iDeck.ipa
fi
if [[ "${IDECK_REQUIRE_MADEIRA:-0}" == "1" ]]; then
  python3 - <<'PY'
import stat
import zipfile

with zipfile.ZipFile("iDeck.ipa") as archive:
    links = [
        item.filename for item in archive.infolist()
        if item.filename.startswith("Payload/iDeck.app/")
        and item.filename.split("/")[2] in ("aarch64-windows", "arm64ec-windows", "i386-windows", "nls", "vulkan", "d3d12", "compat")
        and stat.S_ISLNK(item.external_attr >> 16)
    ]
    if links:
        raise SystemExit("ERROR: Native IPA contains Unix symlinks unsupported by some Windows sideloaders: " + ", ".join(links))
    print("Native IPA runtime contains no Unix symlinks")
PY
fi
echo "Created $(pwd)/iDeck.ipa"
