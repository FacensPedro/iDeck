## What's Changed
### Windows runtime
- 64-bit games use Madeira's prebuilt x64 Windows runtime again instead of the one rebuilt from iDeck's patched Wine (since 2.0.0). With the rebuilt runtime, games such as Dragon Age: Inquisition closed with an access violation (0xC0000005) before any game code ran: the ARM64EC C runtime (ucrtbase.dll), loaded right after the x86-64 translator, crashed during its own initialization, and msacm32.dll failed to initialize. The rebuild can still be turned on in the build with `IDECK_REBUILD_WINE_PE_MODULES=1`.
- The 32-bit (x86) runtime still comes from iDeck's patched Wine.
- The x64 runtime changes, so a new runtime download is published with this build.

### EA app
- EA games that check their licence with EA's activation library get a fresh licence from EA at every launch. Dragon Age: Inquisition refused a licence kept from an earlier launch and opened EA's activation window (ActivationUI.exe), which then crashed; with a renewed licence it went on to start. A kept licence is used only if the renewal fails, and the bug report then says "licence kept (renewal failed)".

### Bugs & logs
- The bug report has a "Missing DLLs:" line listing what the last Windows session could not find, from Wine's own messages: a DLL a program imports that is missing or failed to load, a function with no implementation, an unimplemented function that was called, and a DLL looked up in system32 or syswow64 that is not there. When there are none, the line says so.

### Release
- Updated the application version to 2.0.1 (build 69).
