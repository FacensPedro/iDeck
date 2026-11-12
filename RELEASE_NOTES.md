## What's Changed
### Windows runtime
- Fixed 64-bit games closing at start with an access violation (0xC0000005) while the x86-64 translator (xtajit64.dll) and its DLLs initialize, seen with Dragon Age: Inquisition. A DLL runs from a copy in the JIT pool that was made before its imports were bound; an import table in a writable section was never copied there again, so the DLL read an empty import and crashed. The bound import table of every loaded DLL is now copied into its JIT copy before the DLL's initialization runs.

### Release
- Updated the application version to 2.0.1 (build 69).
