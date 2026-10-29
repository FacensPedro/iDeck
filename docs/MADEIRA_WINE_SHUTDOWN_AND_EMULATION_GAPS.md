# Madeira Wine lifecycle parity and remaining emulation gaps

## Session close: iDeck compared with pinned Madeira

The pinned upstream `willfaust/Madeira` revision
`fd9f2f3d0434a4116e4c3351f286a0fc376b4e36` implements Wine
and wineserver as **threads inside the same iOS application process**.

The upstream `app/Madeira/WineProcessBridge.m` exits `__wine_main`,
waits for surviving game child processes when configured, clears
per-launch graphics/CPU flags, and calls `wineserver_stop()` to join
the wineserver thread. Calling `kill(getpid(), SIGKILL)` or
`pthread_cancel` on the guest from iDeck is **not a safe substitute**:
it can kill or corrupt the iOS host and leave JIT/Metal state invalid.

Before this change the iDeck X button sent Alt+F4 and displayed a
message. The native session remained active until the guest chose
to exit; SwiftUI could not reliably tell whether Wine's wineserver
had also stopped. Native `ideck_wine_session_started` also remained
latched even after the game exited.

The revised close flow:

1. X sends the guest's regular Alt+F4 through Madeira's
   `winios_post_key` queue and marks the session Closing.
2. The Metal display stays attached and the session modal stays
   visible while Wine or wineserver is running.
3. The native completion check verifies **both** Wine process
   and wineserver are no longer running. It clears stale
   `MADEIRA_EXE`, `MADEIRA_ARGS`, Steam app identity and
   working-directory environment values, stops native session
   discovery/memory caches, and releases the launch gate.
4. The coordinator clears active/pending Steam game identifiers,
   changes state to `Windows Ready`, and SwiftUI dismisses the
   full-screen cover back to the existing Steam library workspace.
5. The Wine controller observer is removed on dismissal.
6. If the game ignores Alt+F4 after 15 seconds, iDeck shows
   **Retry Close**, **Keep Waiting**, or **Return to Game**.
   It does **not** pretend the in-process guest has exited.

The source code now supports re-arming a completed native session.
**Actual repeat launches still require device validation**:
upstream Wine and wineserver may retain process-global state even
after a previous guest has exited; a safe, general force-kill or
guaranteed per-game process isolation does not yet exist.

## Priority gaps versus Madeira

| Priority | Upstream capability | iDeck status and follow-up |
| --- | --- | --- |
| P0 | In-process Wine lifecycle and wineserver join | Added clean close detection and native state release. Forced termination of a stuck guest needs a proper Wine-native cooperative exit/abort API; never send SIGKILL to the host PID. |
| P0 | ARM64EC FEX/Wine, DXMT and native D3D12 binaries | Native workflow exists, but default automatic IPA is interface-only. Real shader/JIT/game tests need a licensed native IPA and a device. |
| P0 | Persistent raw UIWindow-hosted Metal presentation and Win32/GDI compositor layout | Recently ported into `WindowsRendererView.swift`. Actual first-frame and desktop-window presentation remain unverified on iPad hardware. |
| P1 | Full GamepadInput-to-Winios/XInput/HID integration | Madeira manages per-session gamepad slot reservation and forwards events into its guest input bridge. iDeck's current `WineInputBridge.swift` mainly supplies `SDL_GAMECONTROLLERCONFIG` on controller connect, without equivalent full gamepad input forwarding or per-game policies. |
| P1 | Guest virtual monitor selection, dynamic ChangeDisplaySettings and presentation mapping | iDeck exports `MADEIRA_SCREEN_W/H` and syncs a window-level compositor, but does not yet implement Madeira's complete `GuestDisplay.swift` mode/scale mapping, per-game Fit/Fill/Stretch/Aspect handling or unified touch transform. |
| P1 | Multiple Wine launches in one app run | Native launch gate is now reset only after both guest and server stop. Run a native regression with two consecutive games; global upstream Wine state can still prevent safe reuse. |
| P2 | Extensive per-game Madeira configuration and diagnostics | iDeck exposes some profiles, JIT and Wine logs, but not all `madeira.cfg` overrides, Win32 window census, guest input/Winemetal performance probes or upstream compatibility switches. |

## Test plan for a real native IPA

- Start a game from the native Steam library; verify that Wine, FEX
  and Metal present counters really advance.
- Tap X and confirm the guest receives Alt+F4 and its window closes.
- Check `[WineProc] stopping wineserver...` and
  `[iDeck Wine] guest and wineserver stopped; session released` in
  the Wine log before the Steam library reappears.
- Launch a **second** game from the same library. Look for stale
  wineserver sockets, Wine process-global state, FEX mappings and
  a blocked JIT pool; a successful interface build cannot prove this.
- Test a frozen game where the Alt+F4 queue is unavailable. Verify
  that the warning appears and the app does not kill its own PID.

This is a scoped lifecycle improvement, not a claim that iDeck has
all Madeira features or can safely force-kill arbitrary hung
in-process Windows games.
