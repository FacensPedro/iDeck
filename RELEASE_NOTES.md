## What's Changed
### Windows runtime
- 64-bit games use Madeira's prebuilt x64 Windows runtime again instead of the one rebuilt from iDeck's patched Wine (since 2.0.0). With the rebuilt runtime, games such as Dragon Age: Inquisition closed with an access violation (0xC0000005) before any game code ran: the ARM64EC C runtime (ucrtbase.dll), loaded right after the x86-64 translator, crashed during its own initialization, and msacm32.dll failed to initialize. The rebuild can still be turned on in the build with `IDECK_REBUILD_WINE_PE_MODULES=1`.
- The 32-bit (x86) runtime still comes from iDeck's patched Wine.
- The x64 runtime changes, so a new runtime download is published with this version.

### Release
- Updated the application version to 2.0.2 (build 70).
