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

echo "Madeira sources checked out at $REV"
echo "Source checkout complete. Run bash scripts/build_native_runtime.sh on macOS to compile, link and package."
echo "Read $DEST/docs/BUILDING.md for the platform toolchains and licensed prerequisites."

