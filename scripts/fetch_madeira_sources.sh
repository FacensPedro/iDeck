#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$ROOT/vendor/Madeira}"
REV="${IDECK_MADEIRA_REV:-c2c1b03a9e36ef986c980b9eae3c14d05a372db1}"

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
if [ ! -d "$DEST/.git" ]; then
  mkdir -p "$(dirname "$DEST")"
  # Partial clone: only the blobs of the pinned checkout are downloaded.
  git clone --filter=blob:none https://github.com/willfaust/Madeira.git "$DEST"
fi

git -C "$DEST" fetch origin "$REV"
git -C "$DEST" checkout --detach "$REV"
git -C "$DEST" submodule sync --recursive
git -C "$DEST" submodule update --init --recursive --jobs 8 --filter=blob:none
python3 "$ROOT/scripts/verify_madeira_sources.py" --root "$DEST" --revision "$REV"

# Early overlays (patches/series.txt, group "early"): the early JIT hole, the ARM64
# CPU area for ARM64 processes in an ARM64EC session, fault diagnostics, concurrent
# DXIL conversion and Wine's idle logging.
python3 "$ROOT/scripts/apply_madeira_patches.py" "$DEST" early

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
if ! grep -Fq 'SERVER_SOURCES=' "$DEST/build/wineserver/build.sh" &&
   ! grep -Fq 'Building wineserver base from source' "$DEST/build/wineserver/build.sh"; then
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

# The Wine submodule (group "wine"): a null ARM64EC thread context query fails cleanly, and
# wow64win passes atoms (values below 64 KB) through its guest pointer conversions.
python3 "$ROOT/scripts/apply_madeira_patches.py" "$DEST" wine

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

# Group "backports":
# - DXMT's iOS shader cache, CPU/GPU sync and resource reuse: reader reopened after
#   the first write, kernel wait instead of yield loops, memory-pressure trims,
#   2 frames in flight by default, bounded shader DB, opt-in pipeline archive.
# - Upstream fixes verified against the pinned Madeira base: ARM64 shared-object
#   alignment in wineserver (#377), iPad Documents/vcruntime directory precedence
#   for VC++ DLLs, RemoteIO slice / shared-mode Wine engine period for game audio
#   (#349). The Wine/FEX/DXMT ABI revision stays pinned.
python3 "$ROOT/scripts/apply_madeira_patches.py" "$DEST" backports

# iDeck's Visual C++ 2005-2022 runtimes for 32-bit code (syswow64) and the
# VC80/VC90 side-by-side assemblies, from Documents/vcruntime.
VCRT_PATCH="$ROOT/patches/ideck-vcruntime-wow64.patch"
if ! grep -Fq 'ideck_link_vcruntime_wow64(fm, prefix);' "$DEST/app/Madeira/WineProcessBridge.m"; then
  git -C "$DEST" apply --check "$VCRT_PATCH"
  git -C "$DEST" apply "$VCRT_PATCH"
fi

# Group "native":
# - FEX's HostFeatures from the device's real sysctl capabilities (the pinned bridge
#   assumed an Apple A15); a missing feature query never enables a JIT instruction.
# - An ARM64EC CONTEXT_INTEGER return needing its original x16/x17 goes through
#   Wine's syscall_dispatcher_return_slowpath; on iOS 27 raise(SIGUSR2) there was
#   caught as a Mach host breakpoint and surfaced as guest C000001D. The patch
#   routes it through Wine's registered Mach exception server.
# - Unaligned LDAR/STLR rewrites emulate the access instead of overwriting a live
#   neighbouring JIT instruction.
# - Pure ARM64 importers (wow64.dll, xtajit.dll) bind to ARM64EC native targets,
#   Nt* syscall exports included, lone-`ret` exports resolve to a native `ret`, and
#   LdrGetProcedureAddress and delay-load importers get native targets too.
# - opengl32's wow64 thunks resolve the 32-bit TEB inside the iOS WoW64 window.
# - The [iat-life] probe skips a WoW64 process's i386 image.
# - An unloaded image retires its anon JIT aliases; the watchdog leaves exited threads.
# - A loaded image's bound import address table is copied into its JIT-pool copy before
#   any DllMain runs (an IAT in a writable section was never synced there).
python3 "$ROOT/scripts/apply_madeira_patches.py" "$DEST" native
[[ -s "$DEST/app/Madeira/iDeckARMHostFeatures.h" ]] || {
  echo "ERROR: native ARM host feature probe header is missing." >&2
  exit 2
}
if grep -Fq 'Features.CPUMIDRs.resize(8, 0x611F0250)' "$DEST/app/Madeira/FEXBridge.mm"; then
  echo "ERROR: Madeira FEX still spoofs the Apple A15 CPU model." >&2
  exit 2
fi
grep -Fq 'brk #0x5a5a' "$DEST/build/ntdll-unix/signal_arm64_ios.c" || {
  echo "ERROR: scoped ARM64EC Mach resume is absent from compiled Madeira sources." >&2
  exit 2
}

# opengl32's wow64 thunks: every 32-bit guest pointer gets the iOS window base.
python3 "$ROOT/scripts/apply_madeira_opengl32_wow_ptrs.py" "$DEST"

# The stock Wine worker reports g_wine_running=0 before joining wineserver,
# and wineserver_start never clears the prior session's stop flag.
# Both make game B fail after game A ends in the same iDeck process.
python3 "$ROOT/scripts/apply_madeira_patches.py" "$DEST" session
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

# Prefix links are replaced only when stale instead of rewritten every launch.
python3 "$ROOT/scripts/apply_madeira_relink_cache.py" "$DEST"

# Wine's Windows files come from the runtime the initial setup downloads.
python3 "$ROOT/scripts/apply_madeira_runtime_root.py" "$DEST"

# Epic, GOG and .exe programs get no Steam identity (SteamAppId/SteamGameId/SteamAppPath).
python3 "$ROOT/scripts/apply_madeira_steam_identity.py" "$DEST"

# Every Wine code page, so a device in any language finds its ANSI and OEM tables.
python3 "$ROOT/scripts/apply_madeira_full_nls.py" "$DEST"

# A child's WINEDEBUG is copied into the environment, not aliased to freed memory.
python3 "$ROOT/scripts/apply_madeira_spawn_env.py" "$DEST"

# A refused ARM64EC context return (the 0xC000001D of 32-bit Direct3D 9 games) logs its reason.
python3 "$ROOT/scripts/apply_madeira_slowpath_diag.py" "$DEST"

# A native SIGBUS/SIGSEGV names the image and symbol of its pc and lr ([bus-sym]).
python3 "$ROOT/scripts/apply_madeira_bus_symbols.py" "$DEST"

# The app can tear down an exited 32-bit program's 4 GB window right after the session.
python3 "$ROOT/scripts/apply_madeira_wow_reclaim.py" "$DEST"

# Wine Staging patch sets and GE-Proton fixes for Windows-side DLLs (patches/wine-compat).
python3 "$ROOT/scripts/apply_madeira_wine_compat.py" "$DEST"

# mscoree remembers that fusion.dll is absent instead of retrying per assembly (group "late").
python3 "$ROOT/scripts/apply_madeira_patches.py" "$DEST" late

echo "Madeira sources checked out at $REV"
echo "Source checkout complete. Run bash scripts/build_native_runtime.sh on macOS to compile, link and package."
echo "Read $DEST/docs/BUILDING.md for the platform toolchains and licensed prerequisites."
