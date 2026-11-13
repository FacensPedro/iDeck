## What's Changed
### Windows runtime
- 64-bit games use Madeira's prebuilt x64 Windows runtime again instead of the one rebuilt from iDeck's patched Wine (since 2.0.0). With the rebuilt runtime, games such as Dragon Age: Inquisition closed with an access violation (0xC0000005) before any game code ran: the ARM64EC C runtime (ucrtbase.dll), loaded right after the x86-64 translator, crashed during its own initialization, and msacm32.dll failed to initialize. The rebuild can still be turned on in the build with `IDECK_REBUILD_WINE_PE_MODULES=1`.
- The 32-bit (x86) runtime still comes from iDeck's patched Wine.
- The Windows runtime (Wine's x64 and x86 files) is inside the IPA again instead of a separate download, so no runtime releases are published.

- Fixed 32-bit programs crashing iDeck with an access violation while they create windows (BioShock, Tor Browser's installer). Windows passes some names as small numbers (atoms) instead of text; iDeck's 32-bit layer turned them into addresses inside the program's memory and Wine read text there that did not exist. Numbers below 64 KB now stay numbers in every conversion, and the 32-bit layer (wow64win.dll) is built from the patched source.

### EA app
- EA game sizes show again: the size request was cancelled whenever its card was redrawn or scrolled away, and the cancellation was saved as "unavailable" until iDeck restarted. The request now finishes on its own, and a cancelled one is asked again.
- EA games that check their licence with EA's activation library get a fresh licence from EA at every launch. Dragon Age: Inquisition refused a licence kept from an earlier launch and opened EA's activation window (ActivationUI.exe), which then crashed; with a renewed licence it went on to start. A kept licence is used only if the renewal fails, and the bug report then says "licence kept (renewal failed)".

### JIT
- When StikDebug opens iDeck and attaches, iDeck prepares Wine's JIT pool right away. Starting a game then no longer sends you back to StikDebug when JIT is already on, even if StikDebug has detached in the meantime.

### Starting another game
- iDeck asks to be reopened before the next game when the last game crashed, when the JIT pool had to shrink, or when less than 1.5 GB of memory is left. A second game started in the same iDeck process after a crash began with 6 GB in use and a 336 MB JIT pool, and crashed too.

### Memory
- When a 32-bit program ends, its 4 GB memory area is returned to iOS as soon as the session has fully stopped, instead of when the next 32-bit program starts. iDeck waits for the game and the wineserver to stop, and the area is kept while any of the program's threads still runs. The JIT pool stays prepared. The log says how much memory came back.
- Store covers are kept in memory by their decoded size (48 MB at most), are scaled down to 1280 px on the long side, and are dropped on memory pressure and when a game session ends; the disk cache brings them back. The memory limit used to count their compressed size, so far more decoded images stayed in RAM.
- SQLite's page caches (DXMT's shader cache and the system frameworks share them) are limited to 32 MB.
- With less than 3 GB left when a game starts, DXMT keeps one frame in flight instead of two, which holds fewer staging buffers; a game's own setting still wins. The shader cache on disk is capped at 128 MB.

### Game screen
- The loading bar goes away as soon as the first game frame arrives; "First Metal frame displayed" used to stay on screen.
- The performance overlay shows the frame time instead of "GPU utilization: unavailable on iOS" (iOS gives apps no GPU utilization counter).
- Network responses are no longer kept in a URL cache: iDeck's shared cache (in RAM and in CFNetwork's Cache.db) is turned off at launch, and GOG game downloads bypass it too. Game files were always written straight to disk; artwork keeps its own small cache.

### Bugs & logs
- A crash in Wine's native code now names the image and function of the faulting address and its caller (`[bus-sym]`), instead of raw addresses only.
- The bug report has a "Missing DLLs:" line listing what the last Windows session could not find, from Wine's own messages: a DLL a program imports that is missing or failed to load, a function with no implementation, an unimplemented function that was called, and a DLL looked up in system32 or syswow64 that is not there. When there are none, the line says so.

### Release
- Updated the application version to 2.0.1 (build 69).
