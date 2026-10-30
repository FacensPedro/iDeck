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
python3 "$ROOT/scripts/verify_madeira_sources.py" --root "$DEST" --revision "$REV"

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

# Madeira's Wine fork already contains the 11.4 iOS/ARM64EC port.
# Never substitute vanilla Wine, since the Mach, PE/Unix and winemetal
# integration depends on the exact pinned Madeira submodule commit.
WINE_VERSION_FILE="$DEST/wine/VERSION"
if [[ ! -s "$WINE_VERSION_FILE" ]] ||
   [[ "$(tr -d '\r\n' < "$WINE_VERSION_FILE")" != "Wine version 11.4" ]]; then
  echo "ERROR: pinned Madeira Wine must be version 11.4 (ARM64EC/iOS fork)." >&2
  exit 2
fi
for source in madeira-d3d12/src/pe/madeira_d3d12.c \
              madeira-d3d12/src/pe/d3d12core.c \
              build/madeira-d3d12/build-pe.sh; do
  [[ -s "$DEST/$source" ]] || {
    echo "ERROR: pinned Madeira native D3D12 source is missing: $source" >&2
    exit 2
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

# The pinned Madeira FEX bridge assumes every iOS device is an Apple A15.
# Patch its FEXCore HostFeatures construction to use actual iOS sysctl
# capabilities. A missing feature query must never enable a JIT instruction.
ARM_HOST_PATCH="$ROOT/patches/madeira-arm-host-feature-probe.patch"
if git -C "$DEST" apply --reverse --check "$ARM_HOST_PATCH" >/dev/null 2>&1; then
  echo "ARM host feature probe patch already applied."
else
  git -C "$DEST" apply --check "$ARM_HOST_PATCH" || {
    echo "ERROR: pinned Madeira FEXBridge source does not match the ARM feature detection patch." >&2
    exit 2
  }
  git -C "$DEST" apply "$ARM_HOST_PATCH"
fi
[[ -s "$DEST/app/Madeira/iDeckARMHostFeatures.h" ]] || {
  echo "ERROR: native ARM host feature probe header is missing." >&2
  exit 2
}
if grep -Fq 'Features.CPUMIDRs.resize(8, 0x611F0250)' "$DEST/app/Madeira/FEXBridge.mm"; then
  echo "ERROR: Madeira FEX still spoofs the Apple A15 CPU model." >&2
  exit 2
fi

# An ARM64EC CONTEXT_INTEGER return needing its original x16/x17 goes
# through Wine's syscall_dispatcher_return_slowpath. On iOS 27 the pinned
# raise(SIGUSR2) path was caught as a Mach host breakpoint, then incorrectly
# surfaced as guest NTSTATUS C000001D. The narrowly scoped patch routes the
# slow return through Wine's already registered Mach exception server and
# restores the complete frame without a sigreturn x17-clobbering trampoline.
# This is native source, not a modification of the public Wine submodule ABI.
ARM64EC_PATCH="$ROOT/patches/madeira-arm64ec-mach-context-return.patch"
ARM64EC_SOURCE="$DEST/build/ntdll-unix/signal_arm64_ios.c"
if git -C "$DEST" apply --reverse --check "$ARM64EC_PATCH" >/dev/null 2>&1; then
  echo "ARM64EC Mach slowpath patch already applied."
else
  git -C "$DEST" apply --check "$ARM64EC_PATCH" || {
    echo "ERROR: pinned Madeira ARM64EC source no longer matches the safe Mach resume patch." >&2
    exit 2
  }
  git -C "$DEST" apply "$ARM64EC_PATCH"
fi
grep -Fq 'brk #0x5a5a' "$ARM64EC_SOURCE" || {
  echo "ERROR: scoped ARM64EC Mach resume is absent from compiled Madeira sources." >&2
  exit 2
}

# The stock Wine worker reports g_wine_running=0 before joining wineserver,
# and wineserver_start never clears the prior session's stop flag.
# Both make game B fail after game A ends in the same iDeck process.
SESSION_PATCH="$ROOT/patches/madeira-repeat-wine-sessions.patch"
if git -C "$DEST" apply --reverse --check "$SESSION_PATCH" >/dev/null 2>&1; then
  echo "Madeira repeat-session lifecycle patch already applied."
else
  git -C "$DEST" apply --check "$SESSION_PATCH" || {
    echo "ERROR: pinned Madeira source does not match the repeat-session lifecycle patch." >&2
    exit 2
  }
  git -C "$DEST" apply "$SESSION_PATCH"
fi
grep -Fq 'int wine_process_thread_finished(void)' "$DEST/app/Madeira/WineProcessBridge.m" || exit 2
grep -Fq '__atomic_store_n(&g_wineserver_should_stop, 0' "$DEST/app/Madeira/WineServerBridge.m" || exit 2

# Apply a scoped source backport only to this pinned Wine ABI. It preserves
# all existing iDeck Mach/FEX/repeated-session patches and rejects drift.
python3 "$ROOT/scripts/apply_madeira_luajit_backport.py" --madeira "$DEST"

# The published i386 Wine farm checks its import closure with
# echo | grep -q under pipefail. grep can close early and cause an EPIPE,
# falsely reporting existing DLLs as missing. Apply an exact, idempotent
# source overlay without modifying the public pinned Madeira revision.
python3 "$ROOT/scripts/patch_madeira_wow64_import_closure.py" --madeira "$DEST"

echo "Madeira sources checked out at $REV"
echo "Source checkout complete. Run bash scripts/build_native_runtime.sh on macOS to compile, link and package."
echo "Read $DEST/docs/BUILDING.md for the platform toolchains and licensed prerequisites."

