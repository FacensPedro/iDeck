# Steam media and security DLL recovery

The native iDeck Wine prefix uses the verified Madeira Steam client components.
An installation may be missing some Windows **Steam client** DLLs even though
`steamclient64.dll` and `steam.exe` are installed. The Wine log records this
as `video64.dll` importing `libavcodec-62.dll`, `libavformat-62.dll`,
`libavutil-60.dll`, `libavfilter-11.dll`, `libswresample-6.dll`
and `libswscale-9.dll`. A separate `SDL3.dll` loader error
`STATUS_INVALID_IMAGE_FORMAT (0xC000007B)` may indicate a wrong-architecture
binary, malformed image or incompatible dependency; it is not proof the DLL
is absent.

## Steam's seven video DLLs

1. Obtain genuine x64 DLLs from the **same Steam client installation you own**.
   Do not use generic DLL-download sites or mix FFmpeg major versions.
2. Place the six exact `lib*.dll` files, plus `video64.dll`, in
   Files → On My iPad → iDeck → `SteamDLLs`.
3. Open the Steam library in iDeck with no running Wine session. The
   `SteamDLLRepair` importer runs off the UI thread, validates x64 PE
   headers and the complete dependency set, and only copies missing regular
   files into `Documents/wine/drive_c/Program Files (x86)/Steam`.
4. The operation is non-destructive: existing files are not overwritten,
   symlinks and incompatible files are refused, and an incomplete group
   is not installed. Read `[steam-dll]` in Bugs & logs.

PE header validation checks architecture and basic structure; it is **not a
digital-signature or authenticity check**. Only use files you obtained from
Steam. Users should match the DLL versions to the Steam build already in
the prefix, or reinstall the matching official Steam client package.

The `SteamRuntimeInstaller` still downloads its pinned, SHA-256-verified
Valve packages. This importer does not replace that verified setup or
silently download unverified binaries.

## SDL3.dll architecture repair

The importer now audits the Steam client once after the Windows prefix is
ready, even if no DLLs have been imported yet. It identifies the PE machine
of the installed `steam.exe` and checks that `SDL3.dll` uses the same
architecture (x86 or x64). A missing or incompatible SDL3 is reported
alongside the missing media components. SDL3 can be imported independently
of the seven-file FFmpeg/video group.

1. Obtain `SDL3.dll` from the same **genuine, compatible Steam Windows
   client build** as the other DLLs. Do not use a copy from another game or
   substitute a 32-bit DLL for a 64-bit client (or vice versa).
2. Put the file in `Files → On My iPad → iDeck → SteamDLLs → SDL3.dll`.
3. With no Wine process running, revisit the Steam library. iDeck validates
   the imported PE architecture and copies it into the Steam client directory.
   If a wrong-architecture SDL3 already exists, iDeck moves the original to
   `SDL3.dll.ideck-incompatible-backup` before copying the replacement.
4. If a copy or verification fails, iDeck attempts to restore the original.
   If a backup already exists it refuses to overwrite it, and reports that
   manual review is required.

This **does not guarantee** that every `0xC000007B` is fixed: a valid DLL
can still depend on another invalid or missing image. The next device Wine
log should be checked to identify the actual loader failure if it persists.
The importer does not download a new, unpinned Steam client or bundle Valve
DLL binaries into the IPA.

The currently pinned, hash-verified Valve client packages are installed by
`SteamRuntimeInstaller`. If Valve's pinned archives do not contain one of
these optional DLLs, the importer needs an owner-supplied matching copy;
fabricating an FFmpeg or SDL3 replacement would be unsafe.

## Wine's MSV1_0.dll and Kerberos.dll

These are security-provider DLLs in Wine's **ARM64EC Wine build**, not Valve
video libraries. iDeck now explicitly builds `msv1_0.dll` and
`kerberos.dll` from the same pinned Wine fork and stages them in
`arm64ec-windows/`. They are never substituted with Windows DLLs from
unknown distributions.

Missing imports alone are not proof that they caused a game's crash.
`0xC000007B` (bad image or architecture) also cannot be repaired by
renaming unrelated DLLs.

## Performance

This repair does not reduce texture quality, resolution, post-processing,
shader fidelity or graphics API features. It avoids repeated missing-DLL
probes and performs large file copies before Wine starts, off the main UI
thread. Any change in game FPS still requires physical-device measurement.
