# Madeira D3D11 on-device acceptance — no simulated success

This document is a test protocol, not a claim that Madeira already runs Windows
on iOS. Use the exact unsigned D3D11 IPA that passes the native GitHub Actions
workflow, then sign and install it with an authorized method. Never redistribute
Apple's Metal Shader Converter or Microsoft VC++ DLLs without permission.

## Requirements

- iPad mini A17 Pro, record the *actual* iPadOS build number displayed in Settings.
- A real iDeck Madeira **D3D11 native** IPA, not an interface-only IPA.
- A reproducible GitHub Actions run whose native build, linker-symbol audit,
  `verify_madeira_bundle.py --graphics d3d11 --require`, legal notices
  preflight, and IPA integrity checks all passed.
- A signing method valid for the installed application and VPN extension.
- StikDebug attached to the **running** iDeck process when its JIT allocator
  requests executable memory. Merely having set CS_DEBUGGED once is not proof.
- A legally acquired x86-64 Windows application with a reproducible launch
  path and, for the graphics test, a D3D11 render path.

## Phase 6 — artifact identity and signature

Record the commit SHA, Actions run ID, native artifact SHA-256, and the
`graphicsBackend=d3d11` manifest, including `d3d12Linked=false`.
Before signing, verify the IPA has no `libmetalirconverter.dylib`,
`d3d12.dll`, `d3d12core.dll`, `madeira_d3d12.dll`, i386 DLL farm, or
WoW64 host modules. Record the SHA-256 of the **signed** IPA as a second
separate identifier. Resigning may modify bundle identifiers and entitlements;
the unsigned IPA audit is not a substitute for checking the final signed app.

If a macOS signing environment is available, run
`scripts/verify_signed_madeira_app.py --app PATH_TO_SIGNED_iDeck.app`
before installing. The script checks the signed app, provisioned entitlements,
and team identity. It cannot grant entitlements or prove that a free
Personal Team will be allowed to use them.

## Phase 7 — live JIT and executable memory

1. Install the **signed** IPA on the actual iPad, open it once, and activate
   StikDebug for that live process.
2. Start an x86-64 executable and retain native diagnostic output showing the
   live debugger readiness test and successful FEX/Wine JIT setup.
3. Inspect messages beginning `[iDeck JIT]` and `[iDeck Wine JIT]`.
   Fail the case if the debugger detaches, the RX region fails validation,
   the RW alias overlaps it, W^X is violated, or Wine cannot use the JIT pool.
4. Repeat with StikDebug detached. A safe refusal (EPERM or another explicit
   failure) is expected; a fabricated pass, hang, or unhandled BRK is a bug.

## Phase 8 — guest launch and repeated sessions

1. Install a legally sourced, minimal Windows x86-64 EXE into a valid Wine
   prefix, with its real path and arguments.
2. Start it from iDeck and retain Wine logs that show the guest thread and
   wineserver starting and the guest process actually running.
3. Close through the guest's normal close action. Wait until the guest and
   wineserver threads have both exited; `ideck_runtime_complete_session`
   must release the session. Do not use `kill(2)` or `pthread_cancel`.
4. Open a second EXE in the same app session. A first run passing and a
   second run failing is not an acceptable result.

## Phase 9 — actual image, input and audio

1. Start a Windows D3D11 program that produces identifiable **guest-generated**
   pixels (not merely the Wine splash screen or the iDeck UI).
2. Record the first visible guest frame and a further sequence of updated
   frames. A present counter alone does not prove pixels were displayed.
3. Test touch, a connected Bluetooth controller if one is available,
   the on-screen keyboard, and UI resize/orientation changes.
4. Play guest-generated audio and check audibility on the iPad, plus Wine
   audio errors and interruptions. An activated AVAudioSession alone is
   **not** proof of guest audio output.
5. Test normal close, background/foreground transitions, then another launch.

## Phases 10–11 — release and acceptance evidence

Attach the following to the testing issue or PR without passwords, Steam
cookies, signing certificates, provisioning private keys, personal paths, or
other sensitive data:

- Actual iPad model and iPadOS build, IPA SHA-256 before and after signing,
  commit SHA, Actions run URL and build configuration.
- Sanitized native Wine/FEX JIT logs, including first launch and second launch.
- Screenshot or recording of a **real** guest D3D11 frame and confirmation of
  input and audibly played guest audio.
- Evidence of normal process/wineserver shutdown without app crash, and
  evidence of a subsequent successful second session.
- Description of the entitlements actually granted by the signing profile.
- Full applicable GPL/LGPL/MIT notices, corresponding sources, modification
  history, and evidence that the distribution method fulfills relinking/source
  obligations. The automated license-notice audit is not a legal opinion.

Record each case as `PASS`, `FAIL`, or `NOT RUN`; never equate
`NOT RUN` with `PASS`. The acceptance gate is complete only when all
required **on-device** cases have real PASS evidence. No macOS CI, simulator,
or source-level unit test can substitute for this.

## Optional future tracks

- **D3D12:** separate build and signed-device test. Must remain disabled
  without an applicable Apple converter distribution license, compatible
  headers/binary, and direct real-device validation. The Madeira Converter
  Exception alone is not proof of Apple permission.
- **WoW64:** separate 32-bit guest and FEX host test, with a verified
  `i386-windows` DLL farm, ARM64 host modules and a 32-bit guest application.
  It is explicitly absent from the initial x86-64 D3D11 profile.
- **Additional games:** matrix by Windows architecture, graphics API,
  shader features, input, audio and known required runtimes. Never label
  a title compatible based only on whether its EXE downloaded successfully.
