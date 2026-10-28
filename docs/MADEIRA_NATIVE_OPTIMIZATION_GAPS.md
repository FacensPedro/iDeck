# iDeck × Madeira: native performance and feature gaps

This audit compares the iDeck source tree with upstream
[Madeira](https://github.com/willfaust/madeira) as of October 28, 2026.
It distinguishes real source-level changes from features that still require
product integration or a device-specific entitlement.

## Ported in this change

| Area | Previous iDeck behavior | New behavior |
| --- | --- | --- |
| Steam existing-file validation | Swift opened files, allocated a 16 MiB buffer per reader, called `pread`, then SHA-1 on every candidate chunk | Swift retains cancellation and task scheduling; C uses a reusable **4 MiB read window**, streams oversized chunks, rejects symlinks, and compares hashes in native memory |
| Steam encrypted chunk decoder | Swift allocated a separate IV `Data`, made nested slices and chained two `CCCrypt` calls for every chunk | Native C now derives the Steam AES IV and decrypts AES-256-CBC/PKCS7 into one output buffer, clears the intermediate IV, and returns an error instead of throwing within unsafe native code |
| Steam CDN URL chunk hashes | Swift called `String(format: "%02x")` 20 times per SHA-1 | C encodes all 20 bytes into a 40-character lowercase ASCII identifier in one pass |
| Steam Cloud local-file SHA-1 | Swift read up to 1 MiB into a new `Data` object on each loop | C uses a **64 KiB streaming buffer**, with regular-file/symlink checks and unchanged SHA-1 protocol |
| Wine diagnostic summary | iDeck primarily exposed a complete Wine log file to share | Added a bounded **512 KiB** C log classifier inspired by upstream `LogSummary` and `LogPattern`. The error UI displays only fixed diagnoses, not raw log contents or account data |

The moved work is in `iDeck/SteamNativeCore.c` and
`iDeck/NativeRuntime/WineLogTriage.c`. The corresponding Swift files still
perform SwiftUI display, Steam networking, permission-safe path resolution,
task cancellation, and data ownership. Keeping a small, documented C ABI is
less risky than moving the entire Steam model or SwiftUI app into Objective-C++.

**Performance note:** These changes remove identifiable temporary allocations
and reduce peak reader buffers from 16 to 4 MiB per file. They are not evidence
of a specific percentage speed increase. The C and Swift smoke tests validate
the same decryption/verification protocols; real throughput and memory gains
must be measured on a signed native IPA on the same iPad and Wi-Fi connection.

## Useful Madeira functionality not fully present in iDeck

| Madeira upstream components | iDeck status | Proposed next work |
| --- | --- | --- |
| `EpicGames.swift`, `EpicLibrary.swift`, `EpicCloud.swift` | Steam library and Steam Cloud exist; Epic client/library/cloud support is absent | Separate Epic authentication, ownership metadata, secure token storage, and cloud conflict handling |
| `ExternalDrives.swift`, `ExternalStorage.swift` | Wine uses local containers; external-drive document-provider storage is not fully integrated | Scoped bookmarks, file coordination, removable-media safety, and slow-I/O testing |
| `TouchControlPresets.swift`, `TouchGamepad.swift`, `GestureZones.swift`, `PadKeyboardMouse.swift` | Physical gamepad and some Wine input hooks exist; complete per-game touch-control overlays and presets are missing | Input-event bridge plus accessible customization and profile persistence |
| `LogSummary.swift`, `LogTail.swift` | This PR adds bounded native error categories; no full per-session searchable streaming log viewer | Async log tail, deduplicated patterns and session reports (never load large logs into SwiftUI) |
| `WineMono.swift` | Microsoft Visual C++ runtime setup is present; Wine Mono install UI/workflow is absent | Signed/verified Mono package source, version compatibility and resumable installation |
| `GameRecommendations.swift`, `GameIniFiles.swift` | Per-game graphics settings exist; upstream recommendations and INI adjustment are not fully implemented | Device-sensitive presets, change preview/rollback and compatibility testing |
| `InteractionFrameRate.swift`, `FPSOverlay.swift` | iDeck has a basic FPS/CPU/Metal HUD and display-link configuration | More complete presentation timing, adaptive frame pacing and per-session statistics |

These are **not** all being claimed as implemented. Large features require
their own tests, source licenses, assets and iPadOS permission review.

## Safety and compatibility checks

- The existing Swift SHA-1 checks and Steam SHA-1 IDs follow Valve's protocol,
  not a new cryptographic security scheme.
- Native C readers refuse symlinks; they do not follow guest-provided paths
  outside the Wine prefix. Native I/O errors mark chunks as needing download
  rather than marking unverified content reusable.
- The downloader still validates compressed chunk bounds, Adler-32, expected
  lengths and other manifest metadata. It can resume from per-depot journals.
- C ABI entry points have null, size, path and overflow checks; the Swift
  layer tests cancellation at the same intervals as before.
- Native Wine diagnostics scan only a recent bounded portion of the log and
  do not guarantee the true fault is in that portion. Logs generated *before*
  Wine's redirected stderr starts are not necessarily captured in it.
- Do not remove Apple JIT, memory or signing checks for throughput; those
  checks prevent unhandled `BRK` crashes and invalid executable memory.
