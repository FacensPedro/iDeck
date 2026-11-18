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
  # Graphics profiles:
  #   unified (default): one IPA with DXMT (D3D11/D3D10/DXGI) and Madeira
  #                      D3D12, sharing FEX, Wine ARM64EC and wineserver.
  #                      Wine loads each API's DLL when a game asks for it.
  #   d3d12:             legacy name of the same build.
  #   d3d11:             DXMT only, without the Apple Metal Shader Converter.
  # The pipeline below builds "d3d12" for both unified and d3d12; the
  # profile name is recorded in the manifest.
  export IDECK_GRAPHICS_PROFILE="${IDECK_GRAPHICS_PROFILE:-${IDECK_MADEIRA_GRAPHICS:-unified}}"
  case "$IDECK_GRAPHICS_PROFILE" in
    unified|d3d12) export IDECK_MADEIRA_GRAPHICS=d3d12 ;;
    d3d11) export IDECK_MADEIRA_GRAPHICS=d3d11 ;;
    *) echo "ERROR: graphics profile must be unified, d3d11 or d3d12." >&2; exit 2 ;;
  esac
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

# Faster CI builds: no code index or dSYM (nobody reads them from an
# unsigned IPA), all cores, targets in parallel, and Swift packages checked
# out into a folder the workflow caches between runs.
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
xcodebuild build \
  -project iDeck.xcodeproj \
  -scheme iDeck \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  -clonedSourcePackagesDirPath "${IDECK_SPM_DIR:-$BUILD_DIR/SourcePackages}" \
  -parallelizeTargets -jobs "$JOBS" \
  -skipPackagePluginValidation -skipMacroValidation \
  COMPILER_INDEX_STORE_ENABLE=NO \
  DEBUG_INFORMATION_FORMAT=dwarf \
  ONLY_ACTIVE_ARCH=YES \
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
  # Microsoft's Visual C++ runtimes are downloaded by the initial setup. Only a
  # build that keeps the runtime in the IPA (IDECK_SPLIT_RUNTIME=0) bundles them.
  if [[ "${IDECK_SPLIT_RUNTIME:-1}" == "0" && "${IDECK_BUNDLE_VCRUNTIME:-1}" != "0" ]]; then
    bash scripts/bundle_vcruntime.sh "$APP"
  fi
  # Ubisoft Connect's and the EA app's installers are not in the IPA: each store's
  # page in Settings downloads its own when the user taps Install.
  # Native builds use the Debug configuration (upstream Madeira's guest code
  # is unreliable in Release). Drop only the debugger's STABS debug map from
  # the executables: exported and global symbols stay for dlsym and crash logs.
  for image in "$APP/iDeck" "$APP/iDeck.debug.dylib"; do
    [[ -f "$image" ]] && xcrun strip -S "$image"
  done
  if [[ "${IDECK_BUILD_WOW64:-0}" == "1" ]]; then
    python3 scripts/verify_madeira_bundle.py --app "$APP" --require --require-wow64 --graphics "$IDECK_MADEIRA_GRAPHICS" --profile "$IDECK_GRAPHICS_PROFILE"
  else
    python3 scripts/verify_madeira_bundle.py --app "$APP" --require --graphics "$IDECK_MADEIRA_GRAPHICS" --profile "$IDECK_GRAPHICS_PROFILE"
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

# Wine's x64/x86 Windows files, Wine Mono and Visual C++ are not shipped in the
# IPA: the farms become release downloads the initial setup fetches, and Mono and
# Visual C++ come from WineHQ and Microsoft. IDECK_SPLIT_RUNTIME=0 keeps them in.
if [[ "${IDECK_REQUIRE_MADEIRA:-0}" == "1" && "${IDECK_SPLIT_RUNTIME:-1}" != "0" ]]; then
  python3 scripts/split_runtime_downloads.py --app "$APP" --out build/runtime-downloads
fi

# Embed the entitlements in the executables (ad-hoc signature, no certificate).
# Sideloaders such as iloader, SideStore, AltStore and Sideloadly read the
# entitlements an app asks for from its code signature and enable the matching
# capabilities (Extended Virtual Addressing, Increased Memory Limit) on the App ID
# before re-signing. An unsigned binary asks for nothing, so iOS never gave iDeck
# the extended address space Windows games need.
embed_entitlements() {
  local binary="$1" entitlements="$2"
  [[ -f "$binary" && -f "$entitlements" ]] || { echo "ERROR: cannot embed $entitlements into $binary" >&2; exit 2; }
  if command -v ldid >/dev/null 2>&1; then
    ldid -S"$entitlements" "$binary"
  else
    # Sign the Mach-O file itself (not the bundle): no resource seal, so the
    # unsigned nested runtime files do not have to be signed first.
    codesign --force --sign - --timestamp=none --generate-entitlement-der \
      --entitlements "$entitlements" "$binary"
  fi
  if command -v ldid >/dev/null 2>&1; then
    ldid -e "$binary" | grep -q "com.apple.developer.kernel.extended-virtual-addressing" \
      || [[ "$entitlements" != *iDeck.entitlements ]] \
      || { echo "ERROR: extended-virtual-addressing missing from $binary" >&2; exit 2; }
  else
    codesign -d --entitlements - "$binary" 2>/dev/null | grep -q "extended-virtual-addressing" \
      || [[ "$entitlements" != *iDeck.entitlements ]] \
      || { echo "ERROR: extended-virtual-addressing missing from $binary" >&2; exit 2; }
  fi
  echo "Embedded $(basename "$entitlements") into $(basename "$binary")"
}
VPN_EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/PlugIns/VPNExtension.appex/Info.plist")"
APP_EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
embed_entitlements "$APP/PlugIns/VPNExtension.appex/$VPN_EXE" VPNExtension/VPNExtension.entitlements
embed_entitlements "$APP/$APP_EXE" iDeck/iDeck.entitlements

# Stream the app directly into a valid IPA, with fast compression and
# symlink/executable-bit preservation; do not duplicate the native app as
# a temporary Payload tree or recompress PNG/ZIP/GZ assets.
python3 scripts/package_ipa.py --app "$APP" --output iDeck.ipa --duplicate-report build/iDeck-duplicate-audit.json
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
