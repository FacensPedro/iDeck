# ARMv8-A and ARMv8.4-A host feature support in iDeck / Madeira

## Scope

iDeck runs on Apple's existing AArch64 hardware; it cannot upgrade the CPU's instruction set. This change makes the pinned Madeira FEX bridge construct its JIT HostFeatures from public iOS sysctlbyname feature flags instead of unconditionally claiming every device is an Apple A15.

Translated x86/x64 guest code is still handled by the bundled Madeira/FEX/Wine components. This patch does not implement an ARM CPU emulator, grant JIT privileges, or imply Windows game compatibility.

## Runtime feature dispatch

The backport patches/madeira-arm-host-feature-probe.patch adds a small C-compatible iDeckARMHostFeatures.h to the pinned Madeira checkout. FEXBridge.mm uses it to select FEX feature bits:

- ARMv8-A compatible baseline: optional AES, CRC32, LSE atomics, RCpc, SHA1/SHA256, PMULL and FCMA are enabled individually only when the OS confirms them.
- ARMv8.4-A related user-mode extensions: FlagM, FlagM2, LRCPC2, SIMD dot product, DIT, LSE2, FP16/FHM are probed individually. SupportsTSOImm9 requires confirmed RCpc and RCpc2; SupportsFlagM2 requires FlagM.
- Unknown or inaccessible sysctl capabilities are treated as unavailable, never as proof of hardware support.
- Logical CPU count comes from hw.ncpu and is bounded from 1 to 64; CPU MIDRs are not fabricated. The log distinguishes an ARMv8.4-A user-mode feature profile from the generic ARMv8-A compatible path.

The "ARMv8.4-A user-mode feature set" label is a useful subset report, not certification of full Arm architectural compliance, which includes privileged features iOS apps cannot query. No privileged CPU identification instructions are executed.

## Native build and prebuilt kits

scripts/fetch_madeira_sources.sh applies the patch to the pinned upstream FEXBridge and verifies the added header. Native compilation in scripts/link_madeira_native.sh then links the patched bridge into libideck_madeira_upstream_bridges.a.

scripts/madeira_native_kit.py rejects old kits without the current patch checksum, and rejects compiled bridge archives lacking the runtime feature-profile marker. This blocks silent reuse of native libraries built before host feature detection.

## Verification

Run:

    python3 -m unittest discover -s tests/host -p 'test_madeira_arm_host_features.py' -v
    python3 -m unittest discover -s tests/host -p 'test_madeira_native_kit.py' -v

The tests exercise a C-compiled mocked sysctl reader, conservative feature gating, upstream patch application and kit signatures. A native iOS build with the Madeira toolchain and an iPad test with StikDebug/JIT are necessary to verify actual FEX code generation and Wine ARM64EC game execution.

## Existing limitations

- The pinned FEX build still has its own initialization, memory mapping, and JIT requirements; changing host-feature flags cannot make an incomplete IPA execute Windows games.
- FEX's upstream hardware-TSO setting is a separate Apple-specific issue and is not inferred from ARMv8.4-A flags.
- No global -march=armv8.4-a build flag is added. A single app binary must remain safe on devices without ARMv8.4-A extensions.
