#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$ROOT/vendor/Madeira}"
REV="${IDECK_MADEIRA_REV:-fd9f2f3d0434a4116e4c3351f286a0fc376b4e36}"

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
if [ ! -d "$DEST/.git" ]; then
  mkdir -p "$(dirname "$DEST")"
  git clone https://github.com/willfaust/Madeira.git "$DEST"
fi

git -C "$DEST" fetch origin "$REV"
git -C "$DEST" checkout --detach "$REV"
git -C "$DEST" submodule sync --recursive
git -C "$DEST" submodule update --init --recursive

# The pinned Madeira script says it builds the ARM64EC PE ntdll, but
# `make -C dlls/ntdll` also links the host ntdll.so. That Unix target
# references Madeira's iOS-only ios_avail_phys hook and fails on macOS.
# Apply the narrow upstream overlay so the native build produces only the
# PE artifact consumed by the iOS app.
PATCH="$ROOT/patches/madeira-ntdll-pe-only.patch"
NTDLL_SCRIPT="$DEST/build/wine-pe/build-ntdll.sh"
if ! grep -Fq 'make dlls/ntdll/arm64ec-windows/ntdll.dll' "$NTDLL_SCRIPT"; then
  git -C "$DEST" apply --check "$PATCH"
  git -C "$DEST" apply "$PATCH"
fi

# Upstream only updates a private prebuilt wineserver archive. Build the
# complete iOS archive from the pinned server sources on clean runners.
SERVER_PATCH="$ROOT/patches/madeira-wineserver-from-source.patch"
if ! grep -Fq 'SERVER_SOURCES=' "$DEST/build/wineserver/build.sh"; then
  git -C "$DEST" apply --check "$SERVER_PATCH"
  git -C "$DEST" apply "$SERVER_PATCH"
fi

for dir in FEX wine dxmt; do
  test -d "$DEST/$dir/.git" -o -f "$DEST/$dir/.git" || {
    echo "Missing Madeira dependency: $dir (check published submodule commits)." >&2
    exit 1
  }
done

# Pinned willfaust/dxmt invokes a private four-argument Metal atomic intrinsic.
# Metal Toolchain 27B47 requires five arguments, and the old call fails to compile.
# Apply the equivalent public Metal atomic operation used by upstream DXMT.
DXMT_SHADER="$DEST/dxmt/src/airconv/shaders/air_tessellation.metal"
DXMT_PATCH="$ROOT/patches/dxmt-metal27-tessellation-atomic.patch"
if [[ ! -f "$DXMT_SHADER" ]]; then
  echo "ERROR: pinned DXMT tessellation shader is missing: $DXMT_SHADER" >&2
  exit 2
fi
if ! grep -Fq 'reinterpret_cast<threadgroup atomic_int *>(out_count), 1, memory_order_relaxed)' "$DXMT_SHADER"; then
  git -C "$DEST/dxmt" apply --check "$DXMT_PATCH"
  git -C "$DEST/dxmt" apply "$DXMT_PATCH"
fi

# Backport only the upstream fixes verified against the pinned Madeira base:
# - ARM64 shared-object alignment in wineserver (#377)
# - iPad Documents/vcruntime directory precedence for VC++ DLLs
# - RemoteIO slice / shared-mode Wine engine period for game audio (#349)
# The Wine/FEX/DXMT ABI revision stays pinned; do not switch submodules to main.
COMPAT_PATCH="$ROOT/patches/madeira-game-compat-backports.patch"
if git -C "$DEST" apply --reverse --check "$COMPAT_PATCH" >/dev/null 2>&1; then
  echo "Madeira game compatibility patch already applied."
else
  git -C "$DEST" apply --check "$COMPAT_PATCH" || {
    echo "ERROR: pinned Madeira sources do not match the game compatibility backport." >&2
    exit 2
  }
  git -C "$DEST" apply "$COMPAT_PATCH"
fi

echo "Madeira sources checked out at $REV"
echo "Source checkout complete. Run bash scripts/build_native_runtime.sh on macOS to compile, link and package."
echo "Read $DEST/docs/BUILDING.md for the platform toolchains and licensed prerequisites."

