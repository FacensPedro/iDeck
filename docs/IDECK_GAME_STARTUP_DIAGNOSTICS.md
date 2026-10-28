# iDeck: Wine game startup and black-screen diagnosis

## Build type matters

The standard GitHub Actions push/PR runs compile an interface-only IPA for
fast validation. That IPA cannot run FEX/Wine/DXMT/D3D12 Windows games.

To compile the native emulator, open **Actions → iOS Build → Run workflow**
on this branch. The manual workflow defaults to **Require Madeira runtime**.
Review the Apple Metal Shader Converter distribution terms and explicitly
enable the corresponding license confirmation only when authorized. WoW64
(32-bit Windows apps and the SteamSetup executable) and Wine Mono can be
selected independently. Native build steps have to succeed before the
**iDeck-Madeira-native** artifact is created.

The app requires a correctly signed installation and a live StikDebug-compatible
debugger during first FEX executable-memory-pool initialization. Seeing a JIT
indicator does not by itself mean that a compatible debugger is still attached.

## Launch order and symptoms

1. Confirm the app has an actual native runtime and a Wine prefix. Missing
   components must be reported instead of opening a blank game session.
2. Confirm the native Metal display callback is exported, the session view
   is attached and its drawable size is not zero. A stale view cannot clear
   the active session's layer.
3. Test a simple standalone 64-bit Windows program before a Steam game.
   This isolates Wine/FEX/JIT startup from Steam DRM and Direct3D.
4. Try a Direct3D 11 application to test DXMT/WineMetal after the basic
   process startup succeeds. D3D12 additionally depends on the licensed
   converter binaries and D3D12 PE components.
5. Compare the displayed native launch status. Error 45 (ENOTSUP) indicates
   a missing optional 32-bit runtime, 1 (EPERM) missing JIT startup permission,
   2 (ENOENT) missing prefix/assets, and 35 (EAGAIN) incomplete native startup.
6. In the game overlay, look for whether `madeira_get_present_count` exists
   and actually advances. `wine_process_is_running` initially reports
   **thread creation**, not proof that the game reached first frame.
7. Games that depend on Valve's Steam client APIs may not launch merely
   because the account is signed into iDeck's library. The current native
   path opens the game's EXE directly and does not implement Madeira Dock's
   authenticated Windows Steam `LaunchApp` path. No DRM is bypassed.

## Understand an immediate Wine exit

The pinned Madeira native Wine bridge exports both `wine_process_exit_code()`
and `wine_crash_exit_status()`. The iDeck host now reads them when a
Windows program ends instead of displaying the same generic error for every
outcome. Exit code 0 is normal termination; NTSTATUS `0xC0000135` often means
a missing DLL, `0xC000007B` an invalid image or CPU architecture, and
`0xC0000005` an access violation.

The Wine launcher may also exit after creating a child process. Madeira
provides an opt-in `MADEIRA_WAIT_CHILDREN=1` compatibility switch, but the
upstream implementation documents possible indefinite waits, so iDeck does
not enable it for every game. A DRM-protected game may require Steam's
Windows client even when its files and real App ID are available.

See [the source-level Madeira comparison](WINE_RUNTIME_GAP_ANALYSIS.md) for
the remaining host/runtime differences and device-test guidance.

## If the application stops or freezes

The previous iPadOS `bug_type: 202` report showed significant cumulative CPU
usage, not a fatal stack trace. It does not identify Metal as the fault and
does not by itself prove a memory limit was exceeded.

Check the latest iPadOS diagnostic under **Settings → Privacy & Security →
Analytics & Improvements → Analytics Data**, using the iDeck incident
timestamp. The full `.ips` report can distinguish a CPU resource report,
a watchdog termination, an uncaught exception or a memory kill.

For detailed Wine warnings during a development test, start the process
with `IDECK_WINE_DIAGNOSTICS=1` in the environment; otherwise the bundled
Wine debug verbosity remains disabled for performance. Do not publish logs
containing Steam credentials or user tokens.

Do not forcibly detach/destroy the active Metal view while an in-process Wine
guest continues running. The pinned upstream WineProcessBridge exposes no
supported safe guest-stop API; the iDeck close control now refuses to
detach an active guest display. If the process is permanently frozen,
terminate iDeck using the iPadOS app switcher.

## Backports from newer Madeira

The pinned Madeira revision remains fixed for ABI and FEX/Wine/DXMT consistency.
During source checkout, iDeck now backports three targeted fixes from Madeira's
October 2026 code:

- **ARM64 wineserver:** 8-byte shared-object allocation alignment to prevent
  unaligned guest/server objects.
- **Audio:** align shared-mode Wine engine period with the actual iOS RemoteIO
  I/O slice; `MADEIRA_AUDIO_IO_MS=0` retains system-chosen buffer duration and
  `MADEIRA_AUDIO_PERIOD_MS=10` requests the old fixed 10 ms engine period.
- **Visual C++:** in addition to the application bundle, Wine scans
  `Documents/vcruntime` for x64 Visual C++ DLLs supplied by the device owner,
  preferring those copies over bundled ones. Automatic first-game setup
  prepares Files → On My iPad → iDeck → vcruntime; if needed, the folder can
  also be created manually with Files. No Microsoft runtime is shipped in the
  IPA or Git repository. The native ARM64EC exemptions for
  `vcruntime140.dll` and `msvcp140.dll` are maintained.

The patch is verified and applied once to the pinned Madeira source checkout.
Precompiled runtime kits created before these backports must be rebuilt to
contain the fixes. Tests of source patch application are not a substitute for
signed-device hardware testing.

## Remaining compatibility work

- Full native FEX/Wine/DXMT/D3D12 macOS toolchain build and hardware tests.
- 32-bit game/SteamSetup validation with optional WoW64 DLL farm.
- Authentication-compatible Steam client launch integration comparable to
  Madeira Dock, without inventing Steam tickets or bypassing DRM.
- Selectively reviewing newer Madeira commits rather than replacing the
  pinned revision without ABI and build validation.
- Root-cause analysis of an actual crash/termination stack after reproducing
  the exact problematic game on the target iPad.
