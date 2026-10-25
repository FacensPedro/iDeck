#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
FEX_IOS_BUILD="$MD/FEX/build-ios"
ARCHIVE="$FEX_IOS_BUILD/FEXCore/Source/libJemallocLibs.a"

if [[ ! -s "$FEX_IOS_BUILD/CMakeCache.txt" ]]; then
  echo "ERROR: iOS FEX CMake configuration is missing: $FEX_IOS_BUILD" >&2
  exit 2
fi

# Madeira's upstream fex-ios/build.sh builds only FEXCore and FEXCore_Base.
# FEX allocator hooks live in a distinct CMake target and must be compiled
# for iOS arm64; the ARM64EC Windows build's similarly named archive is invalid.
cmake --build "$FEX_IOS_BUILD" --target JemallocLibs

if [[ ! -s "$ARCHIVE" ]]; then
  echo "ERROR: FEX iOS allocator archive was not created: $ARCHIVE" >&2
  exit 2
fi

ARCHS="$(xcrun lipo -archs "$ARCHIVE" 2>/dev/null)" || {
  echo "ERROR: FEX iOS allocator archive has no readable Mach-O architecture: $ARCHIVE" >&2
  exit 2
}
if [[ " $ARCHS " != *" arm64 "* ]]; then
  echo "ERROR: FEX iOS allocator archive does not contain arm64: $ARCHIVE ($ARCHS)" >&2
  exit 2
fi

echo "FEX iOS allocator hooks ready: $ARCHIVE ($ARCHS)"
