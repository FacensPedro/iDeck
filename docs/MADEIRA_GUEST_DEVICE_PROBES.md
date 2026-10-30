# Madeira: real iPad Windows guest graphics, audio, touch, controller and restart probes

These programs are original Windows EXEs, not an iOS mock or a build-only substitute.
On macOS, with the pinned llvm-mingw cross-compiler installed, compile them using:

    bash scripts/build_madeira_device_probes.sh

The generated `build/madeira-device-probes/` folder contains:

- `ideck-guest-smoke-32.exe` (i386 PE32) and `ideck-guest-smoke-64.exe` (x64 PE32+), each writes a real guest PID and architecture receipt into Wine's temporary directory.
- `ideck-d3d11-frame-probe-x86.exe` and `ideck-d3d11-frame-probe-x64.exe`, which call D3D11CreateDeviceAndSwapChain, ClearRenderTargetView and Present for 180 alternating red/blue frames.
- `ideck-d3d12-frame-probe-x64.exe`, which calls D3D12CreateDevice, a Direct3D 12 command queue, DXGI swapchain and Present for 120 red/blue frames.
- `ideck-guest-audio-input-x86.exe` and `ideck-guest-audio-input-x64.exe`, which submit a PCM tone through Windows waveOut, poll real XInput buttons and receive WM_TOUCH or mouse/touch events in the Windows guest.
- Import inspection JSON reports and `probe-build-manifest.json` with SHA-256 for each compiled EXE.

## Physical iPad test sequence

1. Install a properly signed *Madeira-native* IPA, attach an authorized StikDebug JIT debugger, and record the iPadOS build, exact commit SHA and unsigned/signed IPA SHA-256. An interface-only IPA cannot execute the probes.
2. Import the guest EXEs into the Wine prefix's `drive_c` folder using the iDeck Windows importer; launch through the Madeira workspace. Do **not** run a Mac executable or simulate launch success.
3. Launch the 32-bit and 64-bit smoke tests twice each. After **each launch**, copy the guest-generated `ideck-guest-smoke-32.log` or `ideck-guest-smoke-64.log` from the Wine guest temporary directory to a *different* evidence filename. Verify clean Wine and wineserver shutdown before the second session.
4. Launch both 32/64-bit D3D11 frame probes. Make an actual iPad screen recording with alternating red/blue guest pixels and preserve the Wine stdout containing `ideck-d3d11-frame-probe: presents=180 hr=0x00000000`.
5. With a licensed, signed Beta 3 D3D12 iOS IPA, launch the x64 D3D12 probe, record its real guest image and stdout `ideck-d3d12-frame-probe: presents=120 hr=0x00000000 exit=0`. This clear/present test **does not** by itself prove shader compilation; run the Madeira D3D12 cube and shader canaries separately.
6. Attach a physical gamepad. Launch the x86 and x64 audio/input probes, press A or Start, tap the guest window on the iPad, and confirm the PCM test tone was audible. Each test writes `ideck-guest-audio-input-32.log` or `ideck-guest-audio-input-64.log`; capture real audio and controller/touch video separately.
7. Restart iDeck and reboot the iPad; repeat at least one successful guest launch, D3D11/D3D12 frame sequence, clean shutdown and audio/input case. Record failures and app/OS crash diagnostics.

Audio/input receipts must contain `waveout_submitted=1`, `waveout_completed=1`, `xinput_connected=1`, `xinput_button_event=1`, and `touch_event=1`. A successful API return alone is **not** proof that audio was physically audible.

## Host-side guest result audit

Copy actual Windows guest stdout and receipts into a **private** `device-evidence` directory. Do not include game binaries, pairing files, signing keys or account data in a public PR. Audit the report format and detect missing tests with:

```bash
python3 scripts/verify_madeira_guest_probe_results.py \
  --root device-evidence \
  --smoke-x86-first guest32-first.log \
  --smoke-x86-second guest32-second.log \
  --smoke-x64-first guest64-first.log \
  --smoke-x64-second guest64-second.log \
  --audio-x86 audio32.log \
  --audio-x64 audio64.log \
  --d3d11-x86 d3d11-32.log \
  --d3d11-x64 d3d11-64.log \
  --d3d12-x64 d3d12-64.log \
  --output guest-probe-format-receipt.json
```

Omit `--d3d12-x64` only when validating a D3D11-only IPA. The host audit rejects malformed logs, symlinks, duplicated first/second guest PIDs, failed controller/touch or waveOut reports and incomplete frame counts. It does not attest that logs came from a physical iPad.

Then complete `scripts/verify_madeira_device_acceptance.py` with independent signed IPA verification, physical first-frame recordings, Wine/JIT shutdown evidence, licenses and reboot-cycle test results. Only a human review of those physical records can homologate stages 8–11 and specific games.
