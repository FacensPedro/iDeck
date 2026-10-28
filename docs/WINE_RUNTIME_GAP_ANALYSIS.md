# Madeira and iDeck: Windows runtime integration audit

Checked on October 28, 2026 against the Madeira source revision pinned in `scripts/fetch_madeira_sources.sh`: `fd9f2f3d0434a4116e4c3351f286a0fc376b4e36`. Changes on Madeira's newer main branch may have different FEX/Wine ABIs and must be backported selectively; do not switch revisions without validating their build and interface contracts.

## What “Wine exited” establishes

The old iDeck message `Wine exited. The Windows program is no longer running.` only reported that the Wine guest session was no longer active. It could mean normal termination, a Windows exception, a missing DLL, an incompatible CPU instruction, a launcher handing off to a child process, Steam DRM requirements, or a graphics initialization failure. It was not sufficient to name the root cause.

Pinned Madeira exports `wine_process_exit_code()` and `wine_crash_exit_status(uint32_t *)` in `app/Madeira/WineProcessBridge.m`. The new iDeck wrapper reads those symbols from the linked runtime. Common NTSTATUS diagnostics include:

| Code | Interpretation |
| --- | --- |
| `0xC0000135` | A required DLL was not found |
| `0xC000007B` | Invalid executable or DLL image, often incompatible architecture |
| `0xC0000005` | Access violation |
| `0xC000001D` | Illegal or unsupported instruction |
| `0xC0000142` | DLL initialization failure |
| `0xC0000139` | Missing DLL entry point |

An exit code of zero indicates the Wine main process ended normally; this is not evidence that a frame rendered, that a Steam game was playable, or that any child process survived.

## Source-based comparison

| Component | Madeira pinned source | iDeck implementation / outstanding gap |
| --- | --- | --- |
| FEX/JIT | FEXCore in-process JIT, iOS guest executable memory pool and host feature probe; implementation in `app/Madeira/FEXBridge.mm` | iDeck builds and links pinned components. Successful FEX JIT allocation and live debugger support need real iPad testing |
| Wine process | In-app wineserver, guest thread and per-session exit codes; `WineServerBridge.m`, `WineProcessBridge.m` | iDeck already starts both. This patch adds exit-code/NTSTATUS reporting instead of a generic message |
| Wine prefix | Snapshot extraction, registry seeding, DOS-device links, architecture-specific system32 DLL links | iDeck imports a checked template and invokes Madeira's native prefix seeder. Prefix contents and registration still require per-device verification |
| Windows DLL loader | Builtin native ARM64EC DLLs with game-configured overrides. DirectWrite is not globally disabled | iDeck previously forced `dwrite=d` and other overrides on every launch. This patch removes them so the Wine loader uses normal defaults and per-game configuration |
| Microsoft Visual C++ | Uses bundled and Documents DLL overlays, preserving native ARM64EC exemptions for `vcruntime140.dll` and `msvcp140.dll` | iDeck already uses this Wine bridge and downloads/extracts Microsoft runtime DLLs. The obsolete manual Settings section is removed; the automatic installer remains |
| Steam identity | Direct game launch sets `MADEIRA_STEAM_APPID` and `MADEIRA_STEAM_APPPATH`; without them, the pinned bridge publishes a fixed test-game identity | iDeck now sends each game's real App ID and installed directory; native launcher checks the directory is inside the requested Wine prefix |
| Steam services | Madeira Dock uses Valve client runtime components and native client-side integration | iDeck's downloaded Windows game EXE cannot automatically replace the real Steam client or DRM path. Some games are still unsupported |
| Child process launchers | `MADEIRA_WAIT_CHILDREN=1` keeps a session alive after the initial launcher exits while valid child processes remain. Upstream documents potential hangs | iDeck does not turn this on globally. Diagnose per title and opt in through Madeira configuration only when needed |
| Graphics | Wine macdrv/Metal, DXMT for D3D11 and D3D12 translation, display surface and present metrics | iDeck bundles the pinned bridges and checks the Metal presentation counter. Real game shader and Metal behavior still require device verification |
| WoW64 | Optional 32-bit guest DLL farm with additional runtime components | iDeck checks whether WoW64 is actually present before launching 32-bit executables. A 64-bit-only IPA cannot run all Steam installers |
| Native readiness | A running Wine process is not equivalent to a fully initialized Windows game | iDeck distinguishes missing native components, failed process launch, stopped Wine session, and no Metal-present activity; this remains an integration effort |

## Diagnosing the next failed launch

1. Build a **Madeira-native** IPA with matching FEX/Wine/DXMT/Metal components. Interface-only CI success does not establish guest execution.
2. On the device, confirm the JIT debugger remains attached while the FEX executable pool initializes.
3. Try a simple DRM-free Windows x64 application without demanding graphics requirements; record the exact native exit code.
4. If the status is `0xC0000135` or `0xC0000139`, inspect DLL loader logs and the imported module names. Do not assume every DLL failure is Visual C++.
5. If the process remains active but no frames render, inspect Metal surface readiness, DXMT/D3D12 shader compilation and the Wine window driver.
6. For Steam titles, distinguish direct EXE launches from Valve client-managed launches. Direct app identity is now corrected, but full client behavior is separate work.
7. For launchers that spawn another process and exit, inspect upstream Madeira's `MADEIRA_WAIT_CHILDREN` option and potential hangs. Do not enable it for every title.

The exact cause of an individual iPadOS failure still requires the Wine stderr/device logs or the specific game process crash report. No claim of complete Windows emulation or Steam game compatibility is made solely on successful compilation.
