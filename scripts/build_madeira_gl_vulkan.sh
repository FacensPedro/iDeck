#!/usr/bin/env bash
# Build the OpenGL and Vulkan host runtimes that upstream Madeira bundles in
# app/Madeira/gl/ (they are not tracked in its repository):
#
#   gl/libMoltenVK.dylib  MoltenVK v1.4.2: Vulkan on Metal. winevulkan loads it
#                         (MADEIRA_VULKAN_LIBRARY) and Zink renders through it.
#   gl/libOSMesa.dylib    Mesa 25.0.7 OSMesa + Zink: desktop OpenGL 3.3-4.x for
#                         the winios WGL driver (build/win32u-unix/opengl_ios.c).
#
# Without libOSMesa the GL driver still runs on Apple's OpenGL ES 3.0 (EAGL),
# which only GLES-capable programs accept. The upstream scripts
# build/moltenvk-ios/build.sh and build/mesa-ios/build.sh do the compiling;
# this wrapper fetches their pinned sources, verifies them and keeps a cache.
#
# Usage: build_madeira_gl_vulkan.sh [MADEIRA_ROOT]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${1:-${IDECK_MADEIRA_ROOT:-$ROOT/vendor/Madeira}}"
APP="$MD/app/Madeira"
CACHE="${IDECK_GL_RUNTIME_CACHE:-$ROOT/build/gl-runtime-cache}"

MOLTENVK_TAG="v1.4.2"
MESA_VERSION="25.0.7"
MESA_SHA256="592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6"
MESA_URL="https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz"

OUTPUTS=(
  gl/libMoltenVK.dylib
  gl/libOSMesa.dylib
  licenses/MoltenVK-Apache-2.0.txt
  licenses/SPIRV-Cross-Apache-2.0.txt
  licenses/SPIRV-Tools-Apache-2.0.txt
  licenses/cereal-BSD-3-Clause.txt
  licenses/Mesa-license.rst
)

die() { echo "ERROR: $*" >&2; exit 2; }

[[ "$(uname -s)" == "Darwin" ]] || die "the iOS GL/Vulkan runtimes require macOS and Xcode."
[[ -x "$MD/build/moltenvk-ios/build.sh" || -f "$MD/build/moltenvk-ios/build.sh" ]] ||
  die "pinned Madeira has no build/moltenvk-ios (run scripts/fetch_madeira_sources.sh)."
[[ -f "$MD/build/mesa-ios/build.sh" ]] || die "pinned Madeira has no build/mesa-ios."

is_arm64_ios_dylib() {
  local file="$1"
  [[ -s "$file" ]] || return 1
  [[ "$(xcrun lipo -archs "$file" 2>/dev/null)" == "arm64" ]] || return 1
  # LC_BUILD_VERSION must name iOS, not macOS or a simulator.
  xcrun otool -l "$file" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b && /platform/{print $2; exit}' |
    grep -Eqx "(2|IOS)"
}

outputs_valid() {
  local base="$1" item
  for item in "${OUTPUTS[@]}"; do
    [[ -s "$base/$item" ]] || return 1
  done
  is_arm64_ios_dylib "$base/gl/libMoltenVK.dylib" && is_arm64_ios_dylib "$base/gl/libOSMesa.dylib"
}

install_outputs() {
  local from="$1" to="$2" item
  for item in "${OUTPUTS[@]}"; do
    mkdir -p "$(dirname "$to/$item")"
    cp "$from/$item" "$to/$item"
  done
}

if outputs_valid "$CACHE"; then
  echo "Using cached MoltenVK $MOLTENVK_TAG and Mesa $MESA_VERSION (OSMesa + Zink)."
  install_outputs "$CACHE" "$APP"
  exit 0
fi

# MoltenVK: Madeira's script expects the source at research/MoltenVK.
MVK="$MD/research/MoltenVK"
if [[ ! -f "$MVK/fetchDependencies" ]]; then
  rm -rf "$MVK"
  git clone --depth 1 --branch "$MOLTENVK_TAG" https://github.com/KhronosGroup/MoltenVK.git "$MVK"
fi
[[ "$(git -C "$MVK" describe --tags --exact-match 2>/dev/null)" == "$MOLTENVK_TAG" ]] ||
  die "MoltenVK checkout is not $MOLTENVK_TAG."
bash "$MD/build/moltenvk-ios/build.sh"
is_arm64_ios_dylib "$APP/gl/libMoltenVK.dylib" || die "MoltenVK did not produce an arm64 iOS dylib."

# Mesa: pinned tarball, SHA-256 checked, plus a private Python tool venv.
MESA_SRC="$MD/research/mesa-$MESA_VERSION"
if [[ ! -f "$MESA_SRC/meson.build" ]]; then
  mkdir -p "$MD/research"
  TARBALL="$MD/research/mesa-$MESA_VERSION.tar.xz"
  [[ -s "$TARBALL" ]] || curl -fL --retry 3 -o "$TARBALL" "$MESA_URL"
  [[ "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" == "$MESA_SHA256" ]] ||
    die "Mesa $MESA_VERSION tarball checksum mismatch."
  tar -xf "$TARBALL" -C "$MD/research"
fi
VENV="$MD/research/mesa-venv"
if [[ ! -x "$VENV/bin/meson" || ! -x "$VENV/bin/ninja" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "meson==1.9.1" "mako==1.3.10" "pyyaml==6.0.3" "packaging==25.0" ninja
fi
MESA_SRC="$MESA_SRC" MOLTENVK_SRC="$MVK" MESA_VENV="$VENV" bash "$MD/build/mesa-ios/build.sh"
is_arm64_ios_dylib "$APP/gl/libOSMesa.dylib" || die "Mesa did not produce an arm64 iOS libOSMesa.dylib."

# libOSMesa must find MoltenVK through @rpath only (no build-machine paths).
if xcrun otool -L "$APP/gl/libOSMesa.dylib" | tail -n +2 | awk '{print $1}' |
   grep -Ev '^(/usr/lib/|/System/Library/|@rpath/|@loader_path/)' | grep -q .; then
  xcrun otool -L "$APP/gl/libOSMesa.dylib" >&2
  die "libOSMesa.dylib links a library outside the app bundle or the system."
fi

outputs_valid "$APP" || die "OpenGL/Vulkan runtime outputs are incomplete."
rm -rf "$CACHE"
install_outputs "$APP" "$CACHE"
echo "Built MoltenVK $MOLTENVK_TAG and Mesa $MESA_VERSION (OSMesa + Zink) into $APP/gl."
