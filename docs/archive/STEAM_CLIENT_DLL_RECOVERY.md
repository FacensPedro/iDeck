# Steam media and security DLL recovery

The native iDeck Wine prefix uses the verified Madeira Steam client components.
An installation may be missing some Windows **Steam client** DLLs even though
`steamclient64.dll` and `steam.exe` are installed. The Wine log records this
as `video64.dll` importing `libavcodec-62.dll`, `libavformat-62.dll`,
`libavutil-60.dll`, `libavfilter-11.dll`, `libswresample-6.dll`
and `libswscale-9.dll`. The client may also fail to load `SDL3.dll`\nwith `0xC000007B` when that DLL or one of its dependencies is incompatible.

## Steam video and SDL3 DLLs

1. Obtain genuine x64 DLLs from the **same Steam client installation you own**.
   Do not use generic DLL-download sites or mix FFmpeg major versions.
2. Place the six exact `lib*.dll` files, plus `video64.dll` and a matching\n   genuine x64 `SDL3.dll`, in
   Files → On My iPad → iDeck → `SteamDLLs`.
3. Open the Steam library in iDeck with no running Wine session, or launch
   a Steam game when no Wine session is running. `SteamDLLRepair` runs on a
   utility thread and checks the Windows x64 PE32+ DLL headers before copying
   to `Documents/wine/drive_c/Program Files (x86)/Steam`.
4. The FFmpeg/video64.dll group is installed only if all seven files will
   be present; SDL3.dll can be repaired independently. An existing malformed
   or wrong-architecture SDL3.dll is moved to
   `SDL3.dll.ideck-invalid-backup` before the valid candidate is installed.
   Backups are not overwritten. Other existing invalid Steam DLLs are
   preserved. Read `[steam-dll]` in Bugs & logs.

PE header validation checks architecture and basic structure; it is **not a
digital-signature or authenticity check**. Only use files you obtained from
Steam. Users should match the DLL versions to the Steam build already in
the prefix, or reinstall the matching official Steam client package.

The `SteamRuntimeInstaller` still downloads its pinned, SHA-256-verified
Valve packages. The pinned packages are not guaranteed to contain the optional
media dependencies or a compatible SDL3.dll. This importer does not replace that verified setup or
silently download unverified binaries.

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
