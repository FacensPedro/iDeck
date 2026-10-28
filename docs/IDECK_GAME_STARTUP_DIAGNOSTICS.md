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

## App closes immediately before the home screen

Do not confuse a **cold-start app crash** with a Wine game-launch failure.
After a previous JIT crash, restarting the process must not automatically
restart FEX, Wine or the debugger.

The iDeck root view now starts without reading a Steam token, creating the
Steam library/session or probing the native FEX/Wine JIT pool. Even native
memory notifications are configured only after the user selects Madeira or
LiveContainer. The Steam model is constructed within the selected workspace,
not in the home-screen root. The runtime and JIT behavior during an explicit
Madeira launch remains unchanged.

This also supports a signed **iPadOS 26 or later** installation; the app and
VPN extension must both advertise `MinimumOSVersion = 26.0`, even though
the build toolchain uses the iOS 27 SDK. Check the installed iPadOS version
and the IPA's actual signed entitlements and bundle IDs before treating a
pre-home termination as a Wine bug. A re-signer can alter both identifiers
and entitlements.

To locate the crash stage, inspect the device console for:

- `[iDeck startup] SwiftUI App initialized without native runtime setup`:
  the SwiftUI application initializer was reached.
- `[iDeck startup] Home view ready; Wine and Steam not initialized`:
  the first home view was rendered and the previous crash is not happening
  in the entry-point setup.

If the first line never appears, investigate the iPadOS `.ips` report for
`dyld`, code signing, minimum OS errors, incompatible binary slices,
`EXC_BAD_ACCESS` and app extension loading. Swift code running after the
entry point cannot repair a loader-time termination. If only the first
line appears, inspect the main-thread exception stack to identify which
SwiftUI/state-model initializer failed. An iOS watchdog or jetsam event
is not the same as a native executable-memory fault.

Export the newest incident from **Settings → Privacy & Security → Analytics
& Improvements → Analytics Data**. If you cannot open iDeck, the crash report
is still accessible from iPadOS Settings. Preserve the existing installation
and game data until it is backed up; changing the signed bundle identifier
can create an independent app container.

## If the application stops or freezes

The previous iPadOS `bug_type: 202` report showed significant cumulative CPU
usage, not a fatal stack trace. It does not identify Metal as the fault and
does not by itself prove a memory limit was exceeded.

Check the latest iPadOS diagnostic under **Settings → Privacy & Security →
Analytics & Improvements → Analytics Data**, using the iDeck incident
timestamp. The full `.ips` report can distinguish a CPU resource report,
a watchdog termination, an uncaught exception or a memory kill.

Madeira writes Wine stdout/stderr and diagnostic messages to
`Documents/madeira-log.txt` during a session. When a launch fails, the
session screen offers **Share Wine log** if this file exists. The file may
include older sessions and personal data; review it before sharing.

Wine exit code 1 is a generic process failure, not a specific missing-DLL
or graphics diagnostic. Inspect `err:`, `[WineProc]`, and game-specific
messages in the log; also check for a launcher spawning another process.

For detailed native Wine traces during a development test, launch iDeck with
`IDECK_WINE_DIAGNOSTICS=1` in its environment. iDeck maps this to
Madeira's `MADEIRA_DEBUG_VERBOSE=1` because Madeira resets `WINEDEBUG` in
its native Wine thread. This can generate very large logs and reduce
performance. The normal setting retains Madeira's lightweight error logging.
Do not publish logs containing Steam credentials or user tokens.

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

## October 28: ARM64EC execute fault, Wine exit 1

A Cuphead device log showed a successful wineserver, an x64 executable and
working directory, then `[pool-ledger] pool not initialised`, RX execution
failure (`PROTECTION_FAILURE`), `0xC000001D` and Wine exit code 1.
The original host initialized FEXCore's small internal JIT pool but omitted
Madeira's **separate** Wine PE executable RX/RW pool and
`WINE_IOS_JIT_RX`, `WINE_IOS_JIT_RW`, `WINE_IOS_JIT_SIZE` exports.

The native launcher now requests a distinct debugger-backed executable RX
region, remaps a writable alias, verifies executable permission and records
the mapping before initializing the wineserver. Failure returns `ENOMEM`
rather than allowing the guest to enter a non-executable ARM64EC dispatcher.

This is an initial conservative pool-placement implementation (384MB with a
256MB fallback), not a replacement for Madeira's profile-dependent 896MB+
split-pool allocator. Allocation still needs a real debugger supporting
Madeira's BRK protocol and a device-level test. If the game's PE code and
FEX translations exceed this budget, larger pool and address-space
placement work will be needed. No new ability to bypass iPadOS signing or
JIT entitlement policy is implied.

If launching through StikDebug with iDeck's `scripts/jit/universal.js`,
the script now explicitly handles Madeira's `BRK #0xf00d` command 3
(page-zero mapping request). An unsupported mapping is reported as failure
instead of leaking a stale register value. This does **not** override
kernel page-zero restrictions. Madeira's more complete upstream debugger
script is at
[Madeira JIT script](https://github.com/willfaust/madeira/blob/main/app/Madeira/madeira-jit.js).


## Wine ARM64EC JIT pool allocation failures

The native host allocates **two different** executable pools: the FEXCore
translator's private pool, and Wine ARM64EC's RX pool with a writable
`vm_remap` alias. A successful `fex_initialize` does not mean Wine's
separate mapping exists.

The iDeck Wine pool now tries 384, 256, 192, 128, 96 and 64 MiB, in order.
A failed allocation releases its regions before trying the next size. The
writable alias first uses a 0x300000000 address hint, with a zero-hint
fallback for the restricted (non-extended) virtual address maps used on
some sideloaded iPads. The pool is **never** replaced with ordinary
non-executable memory.

When you see an ENOMEM startup error:

1. Request JIT **from inside iDeck**, allowing it to supply
   `universal.js` to StikDebug for its BRK #0xf00d calls. The debugger
   must still be attached during pool preparation. Setting CS_DEBUGGED
   from StikDebug's own app list is not sufficient by itself.
2. Inspect the on-device Wine stderr messages tagged `[iDeck Wine JIT]`.
   `debugger could not allocate RX` means the debugger did not reserve
   executable pages; `rejected RX` indicates the placement is not
   usable; `vm_remap failed` identifies an unavailable writable alias;
   `vm_protect(RW) failed` identifies a protection problem.
3. If the smaller sizes also fail, verify the actual signing and memory
   entitlements in the IPA and test a simple 64-bit EXE before Steam.

This change improves fallback and reports the failure stage, but its
success must still be verified on physical iPadOS hardware. It cannot
override iPadOS debugger, signing or virtual-memory limits.

## On-screen JIT failure stages

The Wine executable JIT pool is prepared before the Madeira process begins
redirecting stdout/stderr into `Documents/madeira-log.txt`; that log may
therefore not include a failed allocation attempt. The native host now
publishes its most significant allocation failure stage and the Mach return
code to the game error screen. Stages distinguish missing debugger, failed
RX allocation, invalid RX address or protection, RW alias `vm_remap`, failed
RW `vm_protect`, and failure to export the memory mapping. A successful
subsequent attempt clears the last failure. Preserve the error text or an
Xcode device console trace for the next diagnosis.

## Code 22: Invalid argument (EINVAL)

An iDeck launch may reject an invalid PE file, malformed launch arguments,
an incompatible request payload, or inconsistent Steam app identity. This
error occurs **before** a Wine process is successfully started and is
separate from an ARM64EC memory-pool failure.

The native launcher now reports each request-validation rejection under
`[iDeck native launch] EINVAL`. It accepts a directly launched Steam
game even if an `isSteam` flag is also present; dock mode is limited
to a Steam client launch without direct-game identity. Parsed Windows
arguments containing embedded double quotes and trailing backslashes
are correctly re-quoted rather than automatically rejected.

The on-screen error for code 22 lists the relevant validation categories.
Since imported executables and game arguments vary, retrieve the exact
`[iDeck native launch]` or `[wine-launch]` message if it recurs.


## External StikDebug Enable JIT vs. the Madeira BRK script

StikDebug's normal app-list **Enable JIT** can leave the iDeck process with
`CS_DEBUGGED` but with its debugger **detached**. Madeira's FEX and Wine
execute a special `BRK #0xf00d` request to allocate executable RX pages.
A stale permission flag is not a handler for that request; attempting the
BRK without a live debugger can crash the app.

On opening the **Madeira** workspace, iDeck now detects that state and
requests StikDebug again with its bundled `universal.js` and the current PID,
including when the Wine container has already been initialized. The JIT
settings always expose a reconnect button while the debugger is detached
and the Wine executable-memory pool is not ready. Existing successfully
prepared pools do not need to be allocated again.

### Low-address executable pool and last-failure details

The upstream Madeira `StikJITHelper` uses reserved, non-resident low virtual
pages to advance the allocation frontier above `0x119000000`, where its
position-dependent FEX dispatcher fails. iDeck now applies this bounded
low-VA reservation strategy before requesting its distinct Wine JIT pool.
It retains these placeholders for process lifetime, just as Madeira does.

A valid debugger RX range can span multiple contiguous Mach regions.
The iDeck validator now checks every region for executable permission
without wrongly requiring one large Mach region. The Windows PE image
window, address overflow, unmapped holes, incompatible layouts and missing
RX execution permissions remain rejected. iDeck **does not deallocate**
an untrusted RX address supplied by an external debugger when validation
fails, because it could belong to an existing mapping or executable image.

On-screen errors now distinguish below-frontier addresses, image collisions,
virtual-memory limits, missing execute permission and partial/unmapped
regions. The Settings panel displays both the live debugger connection
and whether Wine's RX/RW pool is prepared. This improves diagnoses and
prevents unsafe cleanup; it does not prove that the debugger or device
can supply valid executable memory. Test with a newly signed native IPA.

### Madeira background-download compatibility

Steam and DLC installers also request iPadOS's **short background execution
grace period** as adapted from Madeira, ending each system task when its
install completes. This does not port Madeira's full iOS 26
`BGContinuedProcessingTask` implementation and does not guarantee that
a download will continue indefinitely after backgrounding the app.

### Explicit debugger RX preparation failure

The bundled `universal.js` now returns **zero** from the JIT BRK request
when StikDebug's `prepare_memory_region` explicitly returns `false`, a
GDB-style error code, or throws. Earlier versions returned an allocated
address even after preparation failed, causing the Wine native host to
report a confusing executable-permission RX validation error. A failed
request is now retried at another size by the native allocator. A debugger
that returns no explicit result remains subject to native Mach executable
permission verification; this does not turn non-executable memory into JIT.
