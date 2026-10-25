# iDeck

**An experimental iOS and iPadOS application for managing Steam libraries, hosted applications, and a Madeira-based Windows compatibility environment.**

iDeck combines a SwiftUI interface with native C, C++, Objective-C, Objective-C++, and Metal components. Its long-term goal is to integrate the [Madeira](https://github.com/willfaust/madeira) runtime, including FEX, Wine ARM64EC, DXMT, and D3D12, with a unified Windows-game library.

> **Project status: experimental.** The default IPA is an **interface-only build**. It does not include a functioning FEX/Wine/DXMT/D3D12 runtime and cannot run Windows games. The native build option compiles and checks upstream components, but successful compilation and actual game execution on iPhone or iPad have not been established.

## Features and scope

- **Steam integration:** sign-in workflow, owned-game discovery, depot download management, install manifests, and local library controls. Individual Steam features depend on account access and upstream services.
- **Windows workspace:** library entries for installed Steam games and imported Windows executables, with app/game details and profiles. Launching Windows games requires a working native runtime.
- **Hosted apps:** LiveContainer-inspired guest app management. Importing an IPA does not guarantee it can run inside another app; code signing, process restrictions, and iPadOS behavior still apply.
- **Rendering configuration:** Metal-based host adapters and configurable rendering options. GPU translation depends on properly built DXMT and D3D12 components.
- **JIT workflow:** external activation through [StikDebug](https://github.com/StikDebug/StikDebug). iDeck does **not** grant JIT permissions or bypass iOS security.
- **Native performance and memory controls:** a bounded C++ task queue, capped scratch-buffer allocations, automatic cache trimming on iPadOS memory warnings, Metal layer configuration helpers, and opt-in timing instrumentation. These utilities do not expand physical RAM or guarantee higher frame rates.

## Architecture

| Layer | Technology | Responsibility |
| --- | --- | --- |
| User interface | Swift / SwiftUI | Navigation, game library, settings, and user feedback |
| Steam services | Swift, C codec helpers | Authentication, downloads, metadata, installation, and cloud-related operations |
| Guest application support | Swift / Objective-C | App import, container management, and host-side integration |
| Runtime adapters | C / C++ / Objective-C++ | Native lifecycle, Wine/FEX bridge interfaces, JIT memory requests, and Metal integration |
| Windows runtime (optional build) | Madeira / FEX / Wine / DXMT / D3D12 | Experimental Windows compatibility components compiled from pinned upstream sources |
| Build and verification | Bash / Python / Xcode | Dependency preparation, archive verification, and regression tests |

See [iOS memory management](docs/IOS_MEMORY_MANAGEMENT.md) for the pressure-aware memory policy and its limitations. No FEX guest pages or system RAM are swapped to disk.\n\nThe native adapters in `iDeck/NativeRuntime/` are **not substitutes** for a complete FEX or Wine implementation. See [runtime integration status](docs/MADEIRA_RUNTIME_INTEGRATION.md), [native build and linking](docs/MADEIRA_NATIVE_LINKING.md), and [performance module documentation](docs/NATIVE_PERFORMANCE.md).

## Requirements

- macOS and a compatible Xcode installation with the iOS SDK to compile an IPA.
- An appropriate signing method and provisioning configuration to install an unsigned build on a physical device.
- A compatible iOS/iPadOS device for testing; iPadOS security restrictions still apply.
- For the native Madeira build: the pinned upstream repositories, ARM64EC and iOS LLVM toolchains, the Metal shader compiler, and additional dependencies installed by the build scripts.
- For game execution: a **verified** native runtime, compatible rendering/input/audio integration, and JIT availability where required. These requirements are not satisfied by the interface-only IPA.

The Xcode project currently targets **iOS/iPadOS 27.0**. See the project settings for the effective minimum OS version and signing identifiers.

## Building

### GitHub Actions: interface-only IPA

1. Open [Actions → iOS Build](https://github.com/FacensPedro/iDeck/actions/workflows/ios.yml).
2. Choose **Run workflow** for the desired branch and leave **Require Madeira runtime** disabled.
3. Download the `iDeck-interface-only` artifact from the successful workflow run.

The default pull-request and branch builds also validate the Xcode target and host-side tests. An interface-only build provides the app interface for testing, **not** Windows-game support.

### GitHub Actions: experimental Madeira runtime

1. Open [Actions → iOS Build](https://github.com/FacensPedro/iDeck/actions/workflows/ios.yml).
2. Select the branch containing the required runtime fixes.
3. Enable **Require Madeira runtime** (`require_madeira=true`).
4. Review the Apple Metal Shader Converter licensing terms. Enable the corresponding license-confirmation option **only if you have the necessary rights to package and distribute the converter**.
5. Run the workflow and review the native build diagnostics and validation steps.

A workflow that fails to compile or link FEX, Wine, DXMT, D3D12, or required archives **does not produce a verified native IPA**. A successful workflow confirms build-time checks only; it does not prove that Windows games start, render, or behave correctly on a device.

### Local build (macOS)

```sh
bash scripts/build_ipa.sh
```

To attempt a required native build after reviewing any required third-party licensing terms and preparing the toolchains:

```sh
IDECK_REQUIRE_MADEIRA=1 bash scripts/build_ipa.sh
```

The build output is `iDeck.ipa` when all required steps pass. The generated IPA is not automatically signed for your device.

The repository uses example identifiers such as `com.example.iDeck`, `com.example.iDeck.VPNExtension`, and `group.com.example.iDeck`. Configure your own team, bundle identifiers, App Group, and provisioning profiles. The Network Extension may require an appropriate entitlement and signing setup.

## JIT and device limitations

iDeck expects JIT to be provided externally where supported, for example through StikDebug. The **Confirm JIT activated in StikDebug** control updates interface state; it is not evidence that executable-memory permissions were granted. JIT state and entitlement availability must be checked on the physical device.

LiveContainer-related app hosting and native Windows execution are constrained by iOS/iPadOS code signing, sandboxing, entitlements, and platform restrictions. A compiled IPA cannot eliminate these requirements.

## Testing and development

The repository contains host tests for project references, guest data containers, download-related utilities, native packaging, the Metal shader/toolchain setup, and native performance primitives.

To run the native performance host tests on macOS:

```sh
xcrun clang++ -std=c++20 -O2 -pthread -x c++ \
  tests/host/NativePerformanceTests.cpp \
  iDeck/NativeRuntime/FEXExecutionScheduler.cpp \
  iDeck/NativeRuntime/GuestMemoryPool.cpp \
  iDeck/NativeRuntime/NativePerformanceClock.cpp \
  iDeck/NativeRuntime/RuntimePerformanceMonitor.mm \
  -o /tmp/ideck-native-performance-tests

/tmp/ideck-native-performance-tests
```

For native module responsibilities and safe ownership rules, see [Native Performance Foundation](docs/NATIVE_PERFORMANCE.md). Performance claims require repeatable benchmarks on actual hardware; enabling a helper module alone does not guarantee an improvement.

## Troubleshooting

- **No Windows executable starts:** verify that the artifact is a native Madeira build rather than `iDeck-interface-only`, then inspect the runtime manifest and native diagnostics.
- **Build fails in FEX/Wine/DXMT:** inspect the first compiler or linker error in the GitHub Actions build log; later missing-artifact messages may be secondary.
- **Metal compiler unavailable:** the native build scripts validate and, when needed, download the optional Metal Toolchain component.
- **JIT is unavailable:** check StikDebug compatibility and device restrictions. A UI confirmation does not activate JIT.
- **Installation or VPN extension signing fails:** configure provisioning and entitlements for the app and the embedded extension.

## Project documentation

- [Native runtime architecture](docs/NATIVE_RUNTIME_MODULES.md)
- [Madeira integration status](docs/MADEIRA_RUNTIME_INTEGRATION.md)
- [Native linking and verification](docs/MADEIRA_NATIVE_LINKING.md)
- [Native performance foundation](docs/NATIVE_PERFORMANCE.md)\n- [iPadOS memory management](docs/IOS_MEMORY_MANAGEMENT.md)

## Upstream projects, licensing, and attribution

iDeck incorporates or adapts code and integration patterns from third-party projects, including [Madeira](https://github.com/willfaust/madeira), [FEX](https://github.com/FEX-Emu/FEX), [Wine](https://www.winehq.org/), [DXMT](https://github.com/3Shain/dxmt), [StikDebug](https://github.com/StikDebug/StikDebug), and [LiveContainer](https://github.com/LiveContainer/LiveContainer). Mentioning a project does not imply endorsement.

Steam-related adapted source retains its upstream notices. Refer to the repository's `LICENSE`, `LICENSES/` directory, and source-file headers for applicable terms. The Apple Metal Shader Converter and other third-party components may require separate authorization; redistribution must respect their licenses.

## Contributing

Contributions should include a reproducible description, focused changes, appropriate tests, and build logs when fixing compiler or runtime failures. Keep interface-only and native-runtime claims clearly separated. For performance work, include before-and-after measurements taken with consistent workloads.

---

**iDeck is a development project, not a validated Windows compatibility product for iOS/iPadOS.**
