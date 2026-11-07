# iPhone Duo support and Madeira runtime acceptance

The iDeck iOS target already includes both iPhone and iPad device families.
The iPhone Duo uses two displays and can resize an active iPhone app from the
closed outer screen to the open inner screen, rotate and enter Split View.
Do not infer a display size from `UIDevice.userInterfaceIdiom`, use
`UIScreen.main`, hardcode logical viewport dimensions or infer full-screen
availability solely from a physical device model.

Sources:
- https://developer.apple.com/iphone-duo/prepare/
- https://developer.apple.com/videos/play/tech-talks/111461/
- https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo

## Changes in iDeck

- The native persistent `CAMetalLayer` is hosted by the active `UIWindow`;
  its initial drawable size and content scale are taken from that window's
  physical viewport, rather than a global screen's fixed 800×600 defaults.
- When the scene resizes after folding, rotation or Split View, the existing
  `layoutViewport` converts the current viewport into the active window,
  repositions the persistent layer and updates the Wine desktop/compositor
  rectangle without replacing the layer or resetting the guest process.
- After the layer has been registered with Madeira, DXMT/Winemetal **owns**
  its drawable size. UI layout code must not write the drawable size in
  response to rotation or folding, as that can cause black frames.
- The performance overlay shows a compact set of counters in compact
  horizontal size classes, preserving close and log-copy controls.
- `verify_madeira_device_acceptance.py` now accepts `device.os_build`
  for iPhone/iOS evidence and preserves the legacy `device.ipad_os_build`
  field for old iPad acceptance reports.

## Build requirements

For maximum use of the iPhone Duo inner and outer displays, build using
**Xcode 27.1 and its iOS 27.1 SDK or later**. A build with an earlier SDK may
run but not take advantage of the entire available screen. To reject builds
made with an older SDK:

```bash
IDECK_REQUIRE_IPHONE_DUO_SDK=1 bash scripts/build_ipa.sh
```

The existing deployment target is unchanged. This option verifies the SDK
used to compile the IPA; it does not enable unrestricted JIT or certify
Windows game compatibility.

## Physical-device regression matrix

For both the closed outer display and opened inner display, test the
following while **a real signed Madeira-native IPA is installed**:

1. Cold app launch: home modes, access to settings, scrolling, focus,
   accessible buttons, QR/account Steam sign-in and Steam library grid.
2. Start a Windows guest. Confirm a native first frame, toolbar visibility,
   touch alignment and that the Wine process continues running.
3. Open/close the iPhone Duo while the game remains active. Confirm the
   native CAMetalLayer survives, guest image isn't black or clipped, touch
   coordinates track the visible guest and the process wasn't relaunched.
4. Rotate in both poses; test an asymmetric safe area and the vertical
   system bars in iOS 27.1, then test Split View on both sides.
5. Connect a physical controller, test XInput/DirectInput, audio PCM and
   input in a real Windows guest; verify multiple Windows app launches.
6. Stop Wine and wineserver, close iDeck, reboot the phone and repeat.
7. For PE32, use original i386 Win32 smoke and D3D11 probes under FEX+Wine
   WoW64. For D3D12, use the signed licensed converter-bearing IPA and
   the D3D12 guest probe plus the separate shader-conversion canary.

Test dynamic layouts in Xcode 27.1 Device Hub, but record physical
observations on the iPhone Duo before declaring hardware compatibility.
Device Hub tests are UI-layout tests, not native guest-execution evidence.

## Remaining Madeira acceptance requirements

| Area | Implemented in source | Evidence still required |
| --- | --- | --- |
| Stage 8 | Native Wine/FEX launch, PE32 machine routing, first/second session probes | First Windows guest and second launch on the real iPhone Duo or iPad, independent PIDs, clean Wine+wineserver shutdown |
| Stage 9 | Metal layer/compositor, D3D11 probes, D3D12 probe, original PCM/XInput/touch probes | Actual first and successive guest-generated frames, audible guest audio, physical controller and aligned touch across unfolded/folded layout |
| Stage 10 | IPA build, manifests, legal notices and signed-IPA/evidence verification tools | Native signed and installed IPA for each tested profile; inspect entitlements, licenses, hashes, corresponding source; permission for proprietary converter |
| Stage 11 | Regression checks, crash diagnostics, evidence auditor | Repeated sessions, reboot/relaunch, thermal/memory stability, per-game pass/fail evidence and manual review |
| D3D12 | Optional public Windows PE frontends, converter Beta 3 input pipeline, canary fixtures | Complete licensed native D3D12 IPA with validated Metal Shader Converter 4.0 Beta 3; shader conversion, swapchain and game frames on hardware |
| WoW64 | i386 Windows DLL validation, FEX/Wine WoW64 opt-in/default native profile, PE32 test programs | Native WoW64 payload actually compiled and signed; genuine 32-bit guest execution, JIT/RX mapping and 32-bit D3D11 frames on hardware |
| Game compatibility | VC++ compatibility, opt-in Wine Mono, DirectInput/XInput, XAudio, static import and delayed-import preflight | Device-level testing for Steam, .NET, legacy DirectX/Vulkan/OpenGL games, anti-cheat/DRM limits, game-specific logs, audio and GPU performance |

Every item that requires physical evidence remains **NOT RUN** without a
recording, exact device and OS build, signed IPA hash and original guest logs.
Use `docs/MADEIRA_GUEST_DEVICE_PROBES.md` and
`scripts/verify_madeira_device_acceptance.py` to collect and audit these
results. Neither a successful CI build nor a synthetic test implies that a
Windows game has run on an iPhone Duo.
