## What's Changed
### Windows runtime
- Wine now carries 41 patch sets from Wine Staging 11.4 and 7 fixes from GE-Proton, 73 patches in all. They cover Windows-side DLLs: Direct3D extensions (d3dx9), DirectDraw, DirectInput, DirectMusic, XACT, GDI+, WIC (GIF and TIFF), common controls and dialogs, rich edit, user32, shell32, OLE Automation, MSXML, MSHTML, MSI, WinINet, urlmon, crypt32, ncrypt, Schannel, rtworkq, XInput and DirectWrite.
- These patches reach the x86 (32-bit) DLLs, which iDeck compiles from this Wine tree. The x64 DLLs are Madeira's prebuilt ones and are not changed by this release.
- Patches that touch wineserver, ntdll, kernelbase, win32u, wined3d, the loader or a Unix driver are not included: Madeira replaces those parts with its iOS ports. No patch from Proton itself could be taken for that reason. The full list and sources are in `patches/wine-compat/SOURCES.md`.

### 32-bit Direct3D 9 games
- BioShock and Assassin's Creed IV stop with 0xC000001D at one place: the runtime's context return after the game's first debug message is refused in 32-bit processes. That is not fixed in this release. The refusal now writes its reason and the values it tested to the log, so the next bug report shows which check fails.

### Release
- Updated the application version to 1.7.5 (build 57).
