#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}"
TOOLCHAINS="$MD/toolchains"
MINGW_VERSION="20260421"
MINGW_NAME="llvm-mingw-${MINGW_VERSION}-ucrt-macos-universal"
MINGW_SHA256="bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7"
LLVM_REF="${IDECK_LLVM_REF:-llvmorg-15.0.7}"
JOBS="${IDECK_LLVM_JOBS:-4}"

[[ "$(uname -s)" == "Darwin" ]] || { echo 'ERROR: macOS runner required.' >&2; exit 2; }
[[ -d "$MD" ]] || { echo "ERROR: Madeira checkout missing: $MD" >&2; exit 2; }
for tool in git curl shasum tar cmake ninja xcrun xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing $tool" >&2; exit 2; }
done
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: IDECK_LLVM_JOBS must be a positive integer.' >&2; exit 2; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null
mkdir -p "$TOOLCHAINS"

MINGW="$TOOLCHAINS/$MINGW_NAME/bin/arm64ec-w64-mingw32-clang"
if [[ ! -x "$MINGW" ]]; then
  ARCHIVE="$TOOLCHAINS/$MINGW_NAME.tar.xz"
  URL="https://github.com/mstorsjo/llvm-mingw/releases/download/$MINGW_VERSION/$MINGW_NAME.tar.xz"
  echo "Downloading verified ARM64EC toolchain: $URL"
  curl --fail --location --retry 3 --retry-delay 5 --output "$ARCHIVE.part" "$URL"
  ACTUAL="$(shasum -a 256 "$ARCHIVE.part" | awk '{print $1}')"
  [[ "$ACTUAL" == "$MINGW_SHA256" ]] || { rm -f "$ARCHIVE.part"; echo "ERROR: llvm-mingw checksum mismatch ($ACTUAL)." >&2; exit 1; }
  mv "$ARCHIVE.part" "$ARCHIVE"
  tar -xJf "$ARCHIVE" -C "$TOOLCHAINS"
  rm -f "$ARCHIVE"
fi
[[ -x "$MINGW" ]] || { echo 'ERROR: llvm-mingw installation failed.' >&2; exit 1; }
"$MINGW" --version | head -n 1

LLVM_SRC="$TOOLCHAINS/llvm-project"
LLVM_HOST="$TOOLCHAINS/llvm-host-build"
LLVM_IOS="$TOOLCHAINS/llvm-ios-build"
LLVM_CONFIG="$LLVM_IOS/include/llvm/Config/llvm-config.h"

if [[ -f "$LLVM_CONFIG" ]] && compgen -G "$LLVM_IOS/lib/*.a" >/dev/null; then
  echo 'LLVM iOS headers and static libraries already present.'
  exit 0
fi

if [[ ! -d "$LLVM_SRC/.git" ]]; then
  echo "Fetching LLVM sources at $LLVM_REF"
  git clone --depth 1 --filter=blob:none --branch "$LLVM_REF" \
    https://github.com/llvm/llvm-project.git "$LLVM_SRC"
else
  git -C "$LLVM_SRC" fetch --depth 1 origin "$LLVM_REF"
  git -C "$LLVM_SRC" checkout --detach FETCH_HEAD
fi

cmake -S "$LLVM_SRC/llvm" -B "$LLVM_HOST" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD=AArch64 \
  -DLLVM_ENABLE_PROJECTS= \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_ZLIB=OFF
cmake --build "$LLVM_HOST" --target llvm-tblgen --parallel "$JOBS"

TBLGEN="$LLVM_HOST/bin/llvm-tblgen"
[[ -x "$TBLGEN" ]] || { echo 'ERROR: llvm-tblgen not generated.' >&2; exit 1; }

cmake -S "$LLVM_SRC/llvm" -B "$LLVM_IOS" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 \
  -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
  -DLLVM_TARGET_ARCH=host \
  -DLLVM_TARGETS_TO_BUILD= \
  -DLLVM_ENABLE_PROJECTS= \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_TABLEGEN="$TBLGEN"
cmake --build "$LLVM_IOS" --parallel "$JOBS"

[[ -f "$LLVM_CONFIG" ]] || { echo "ERROR: LLVM generated header missing: $LLVM_CONFIG" >&2; exit 1; }
compgen -G "$LLVM_IOS/lib/*.a" >/dev/null || { echo 'ERROR: no iOS LLVM archives were built.' >&2; exit 1; }
printf 'LLVM iOS toolchain ready: %s\n' "$LLVM_IOS"
