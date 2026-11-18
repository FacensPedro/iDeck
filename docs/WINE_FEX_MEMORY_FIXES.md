# Wine/FEX memory and startup corrections

This change targets the pinned Madeira revision `c2c1b03a9e36ef986c980b9eae3c14d05a372db1` and its pinned FEX/Wine submodules. It does not replace the runtime or change the app version.

## Changes

- **LayerKit VA geometry:** the old tag-51 probe used the minimum and maximum of up to 128 allocations as one exclusion. Disjoint allocations could therefore exclude most of the guest VA. Sort the probe addresses and retain only the largest contiguous band. The failed-allocation scanner also skips a native mapping when the requested allocation starts in a hole but overlaps that mapping, and releases the object port returned by `mach_vm_region`.
- **FEX guard-page result:** the Windows `VirtualProtect` wrapper used `== 0`, reporting success as failure, and passed a null old-protection output. Supply a valid output and use the Win32 nonzero-success convention. Do not remove Wine's no-read sync guard: it runs after protection succeeds and prevents memcpy from an unreadable source. `PAGE_NOACCESS` is the Win32 constant 1, not POSIX `PROT_NONE`.
- **FEX sandbox data:** the environment variable was already set to `C:\ProgramData\fex-emu\`, but FEX's global-data lookup ignored it. Honor a nonempty explicit override for global data on iOS-host builds as well. Retain the DOS path because this FEX module runs inside Wine.
- **Fonts:** build Wine's `vgasys.fon` and `vgafix.fon` with a separate host FreeType converter, generate the CP437 `vgaoem.fon` from Wine Fixedsys, and include these resources in both the app's `fonts` directory and cached runtime kits. Reject kits missing required bitmap fonts. The iOS bundle's existing Wine data directory is the bundle root, so no unreferenced `Resources/fonts` directory is introduced.
- **Executable details:** put Uninstall immediately after Launch, before the profile form.

## Existing behavior retained after source inspection

- **ARM64EC callbacks:** `BTCpu64IosReleaseThreadHolds` already goes through `arm64ec_redirect_ptr`, an RX alias, a self-test, and per-PEB registration. Raw export addresses must not be armed. Exact guest RIP reconstruction also has a native decoder in `signal_arm64_ios.c`. Clarify the obsolete raw-export diagnostic without changing the shared PE/Unix ABI.
- **VA profile ordering:** the dispatcher already hands the natively reserved arena to the current FEX module through exported data before its allocator initialization. A blank selector log at dispatcher init is expected on this path. Clarify that message; do not force a fixed arena into an unverified address range or invoke a selector before CRT initialization.
- **Byte accesses:** STRB and STLRB already have alias emulation. An 8-bit access cannot be misaligned, and inserting an alignment backpatch can overwrite a live neighboring instruction. Preserve the existing handlers and their memory-ordering behavior.
- **Memory entitlements:** both `com.apple.developer.kernel.increased-memory-limit` and `com.apple.developer.kernel.extended-virtual-addressing` are already in `iDeck/iDeck.entitlements`. Effective availability depends on signing and the device. The runtime already falls back from the denied Jetsam query to `os_proc_available_memory` plus footprint. Adding duplicate entitlements would not remove Jetsam limits.

## Validation

Compiled host regression tests exercise the actual protection-result change and contiguous-band selection, including disjoint, empty, single, unsorted, and repeated observations. Existing payload and kit tests check packaging. All new patches are applied against the pinned sources and are registered in `patches/series.txt`; GitHub Actions runs the new tests and validates font-script syntax.

An iOS build and device launch are still required to establish guard-page behavior in the dual-mapped JIT pool, launch-time improvements, font rendering, and memory-pressure stability. Host tests alone cannot establish those results.
