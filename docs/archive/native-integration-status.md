# Native Madeira integration

The native build uses the pinned Madeira iOS forks; these components are not
substituted with UI readiness flags. `IDECK_REQUIRE_MADEIRA=1` enables the native
Xcode configuration and fails packaging when required binaries are absent.

| Component | Integration in iDeck |
| --- | --- |
| FEX | `build_madeira_components.sh` compiles FEXCore, its dependencies and ARM64EC `xtajit64.dll`; `link_madeira_native.sh` compiles `FEXBridge.mm` and links the archives. Native FEX initialization has a strong link reference. |
| Wine ARM64EC | Builds Unix ntdll, wineserver and win32u; stages PE modules and `prefix-template.tar.gz`. Native process and server calls have strong link references. |
| DXMT | Builds the native renderer and Windows frontends. The LLVM cache now contains source and generated headers; a real iPhoneOS compiler probe checks transitive includes before the expensive native build. The combined archive is recreated with the current LLVM libraries. |
| D3D12 | Builds Madeira's PE frontend, `d3d12.dll` and `d3d12core.dll`; stages the supplied Metal Shader Converter and its notices only with the existing license acknowledgment. This does not establish that every D3D12 game is compatible. |
| Launcher | Seeds and validates the prefix, initializes FEX and Wine's separate JIT pool, starts wineserver, sets `MADEIRA_EXE`/`MADEIRA_ARGS`, then calls `wine_process_start(prefix)`. |
| Display and input | Links `IOSDisplayShim`, Winios, XInput/HID and controller output; presents through the existing Wine Metal layer. Packaging now also requires input and process completion exports. |
| Audio and shutdown | Existing AVAudioSession/CoreAudio setup and coordinated guest/server completion remain in use. Live Wine threads must not be forcibly cancelled. |
| JIT | Existing checks inspect the live debugger and validate Wine RX/RW memory mappings. StikDebug must handle Madeira's BRK protocol during pool creation. A UI confirmation alone cannot enable JIT. |
| Xcode/link | Both source builds and imported runtime kits retain and export the required native symbols, including in Release builds. Missing implementations fail linking or bundle verification. |

## Build and validation limits

Run the **iOS Build** workflow with native Madeira enabled, or run
`scripts/build_native_runtime.sh` on a Mac with the required Xcode SDK and tools.
Review the Metal Shader Converter agreement before setting its acknowledgment.
The source-build path prepares the toolchains itself, including repair of the
old generated-headers-only LLVM cache.

The generated IPA remains unsigned for sideloading. A signing identity,
provisioning profiles and a device are not provided by this change. Sign with
the intended sideloading workflow before installation. A passed host test or
symbol audit is not proof of successful JIT, rendering, sound or game execution.

Device acceptance still requires: attach StikDebug; start a Windows game;
confirm the first rendered frame, sound and controller input; close the game;
and launch a second session without restarting iDeck. Check D3D11 and D3D12
separately. Preserve Wine logs and the native build diagnostics when reporting
failures.
