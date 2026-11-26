## What's Changed
### Build
- Fixed the IPA build stopping while it fetched LuaJIT: the source is now fetched as the one pinned commit, retried on a network error, and skipped when the compatibility DLL was already built from it.
- Fixed a warning that left the 64-bit Direct3D stand-in DLLs unbuilt.

### Version
- Updated the application version to 2.16.3 (build 127).
