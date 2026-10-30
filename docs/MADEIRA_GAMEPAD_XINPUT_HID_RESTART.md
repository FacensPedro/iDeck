# Madeira-level XInput/HID controller transport and consecutive Wine games

## Native controller integration

The pinned upstream Madeira source already compiles `Winios/WiniosGamepad.c`,
`Winios/WiniosGamepad.h`, `PadOutput.m` and the virtual HID controller
implemented in `build/wineserver/hidpad_ios.c`. iDeck previously configured
an SDL mapping string but did **not** publish physical `GameController`
snapshots into those C transports.

`iDeck/NativeRuntime/DirectInputBridge.mm` now supplies the application-side
producer, while the original Madeira code remains the consumer:

- Four stable physical-controller slots (0–3) with hot-plug and disconnect,
  standard XInput button masks, both thumbsticks (full signed `Int16`
  range), analogue triggers and controller connection state.
- Controller snapshots are published through
  `winios_gamepad_set_state`, with packet numbering owned by upstream
  Madeira's native transport.
- In HID, DualSense HID or Generic HID mode, player 1 is exported
  through `winios_hidpad_set_state`, including touchpad click, trigger
  digital states, battery level and charging state. The virtual HID
  device is initialized **before** wineserver starts and enumerates PnP
  devices. In the default HID mode the first connected Sony controller
  receives a DualSense identity; a different controller receives the
  generic HID identity.
- HID player 1 does not appear to XInput by default. A user explicitly
  opting into `MADEIRA_HIDPAD_XINPUT=1` can expose both APIs. Players
  2–4 remain XInput.
- The native `PadOutput.m` consumer is used unchanged: XInput rumble,
  virtual DualSense output reports, supported adaptive-trigger effects,
  lightbar and player-index requests map to the corresponding
  `GameController`/`CoreHaptics` APIs where iPadOS allows them. A
  controller or iPad without the required hardware capability cannot
  implement that particular effect.
- The snapshot timer runs only with a paired extended controller and
  an active application (8 ms sample period); backgrounding neutralizes
  input and stops haptics.
- When a Wine session exits, the gamepad state is disconnected, pending
  vibration is cleared, pad output observers are removed and all slots
  are made available to the next game.
- On iOS 18+, the game session claims `.gamepad` events so UIKit
  focus navigation does not consume the guest controller input.

The native bridge is compiled for every IPA, but its consumer-side
symbols are resolved dynamically. **An interface-only IPA cannot
simulate native XInput/HID without the compiled Madeira runtime.**
`scripts/link_madeira_native.sh` now refuses a real native build if
the original XInput/HID producer and output symbols are absent.

## Per-game configuration

Each game profile now stores `controllerAPI`, decoded with
`Automatic` as the fallback for existing profiles. Options:

- Automatic: use the global default in iDeck Settings (XInput).
- XInput: standard virtual Xbox-compatible controller.
- XInput + DirectInput: enable Madeira's optional DirectInput pad.
- HID: virtual DualSense for a Sony controller, generic HID otherwise.
- DualSense HID: force a virtual DualSense identity.
- Generic HID: force a generic controller identity.

The environment variables `MADEIRA_PAD_MODE` and
`MADEIRA_DINPUT_PAD` are set before starting Wine. Stale HID identity
variables from the previous game are cleared before configuring the
next one.

## Consecutive games without restarting the app

The previous iDeck session close logic waited for Wine and wineserver
but did not distinguish `g_wine_running=0` from completion of the
native Wine thread's final destructor/TEB cleanup. It also relied on
the pinned Madeira `wineserver_start` implementation, which leaves
`g_wineserver_should_stop` set after a previous shutdown.

`patches/madeira-repeat-wine-sessions.patch` now:

1. Exports `wine_process_thread_finished()`, written with release
   ordering only after the guest thread's Wine/wineserver and TEB
   cleanup. The native iDeck wrapper reads this with acquire ordering.
2. Rejects a second Wine worker start until the first has finished.
3. Clears `g_wineserver_should_stop` before starting a fresh wineserver
   instance, after confirming the previous instance is no longer
   running.

The coordinator dismisses the guest and re-arms the native launcher
only after the Wine thread, wineserver and worker cleanup are complete.
Per-game launch environment variables, input snapshots and native
per-session caches are then cleared.

The reusable native-kit format stores a checksum of the new upstream
backport. Old cached kits without this patch are rejected, rather
than falsely claiming support for repeat launches.

**On-device validation still matters.** The Wine and FEX runtimes keep
some process-global state, and a complete repeat-game launch must
be validated on a real iPad with the full licensed native runtime.
These changes cover identified restart blockers but cannot prove every
Windows title will tolerate in-process Wine reuse. If a guest ignores
Alt+F4, force-killing the host PID remains unsafe; the existing close
warning and retry controls are preserved.

## Compatibility and known limits

- Apple's GameController API does not expose the physical controller's
  raw USB/Bluetooth HID packets. Madeira's device is a **virtual HID**
  device served to the guest through Wine, not raw hardware passthrough.
- Advanced DualSense speaker, microphone LED, and device audio
  channels cannot be controlled through the public iPadOS APIs.
- Raw `WM_INPUT` HID messaging and some Windows HID consumers are
  limitations of the pinned Madeira guest implementation, not
  capabilities supplied by this iDeck UI integration.
- Native XInput and HID output needs the matching Wine
  `win32u`/XInput and wineserver modules from the pinned Madeira
  revision. A generic Wine build does not provide them.

## Validation plan

Run `tests/host/test_madeira_xinput_hid_restart.py` and the existing
native-kit and safe Wine shutdown tests. CI additionally syntax-checks
the Objective-C++ GameController bridge for iPhoneOS and compiles
the complete iDeck interface.

After an authorized native build, test: controller hot-plug and
disconnect, all four XInput slots, HID-only player 1 with DirectInput
and the reported PS5 identity, supported haptics and player LEDs,
background/foreground input release, a full Wine shutdown, and **two
different Steam games in sequence** without terminating the iDeck app.

## Touchscreen virtual XInput controller (per-game)

The profile now persists `touchControlPreset` with built-in values
`xbox`, `minimal` and `off` (legacy profiles default to `xbox`).
The GameSessionView draws a virtual left stick zone, D-pad and Xbox face
buttons without requiring a physical gamepad. Every press/release and
thumbstick movement is submitted through the existing
`DirectInputBridge.mm` into Madeira's `winios_gamepad_set_state`
(and `winios_hidpad_set_state` where the session selects HID).
No replacement XInput implementation or parallel emulation transport
is installed.

The virtual device uses the first free of the original four XInput
slots: connected physical `GCController` devices are never overwritten.
The native sampling timer stays active while a touch device is enabled.
When a game closes, goes into background or the overlay disappears,
button and analog state is released; Wine session completion still
unpublishes all four slots, cancels rumble and removes system observers.
The UI host reserves a bottom touch interaction band so the separate,
window-level `CAMetalLayer` cannot intercept on-screen button gestures.
When `off` is chosen, it does not reserve that band.

The subsequent surface-scaling integration uses the same monitor
transform for touch mapping and compositing; the native input bridge
does not report a rendered first frame or working game by itself.
The host regression checks ensure slot transport, guest session cleanup,
preset persistence and visible touch control wiring. Real guest XInput
events, analog sensitivity, onscreen ergonomics and device touchscreen
performance remain **NOT RUN** until tested with a signed Madeira-native IPA.
