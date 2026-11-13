## What's Changed
### Epic Games
- Epic games install only the base game: files that carry install tags (language packs, high-resolution textures, optional modes) are left out, so a game takes the space its page shows. A build whose files are all tagged is installed whole.
- Epic DLC can be installed and uninstalled like Steam DLC. An installed game's page lists the downloadable DLC the account owns, with Install, progress, Cancel and Uninstall. A DLC is installed into its game's folder and updated with the same downloader. Uninstalling removes only the DLC's own files, and uninstalling the game removes its DLC too.

### Storage
- Settings › Storage & Downloads shows how much space is free on this device and on each external drive (free of total), or "Not connected" for a drive that is not plugged in.

### Memory diagnostics
- During a game, iDeck logs its memory every 30 seconds for 10 minutes: footprint, memory still allowed by iOS, the launcher and whether Madeira Dock runs. The bug report includes these lines, to show where memory grows (Steam's client in Madeira Dock, the game, or over time).

### Fixes
- A JIT pool that had to shrink no longer blocks the next game with "restart iDeck": it happened on a fresh launch too, so reopening could not help and no game could start. The pool prepared when StikDebug attaches keeps a 192 MB executable window free instead of 256 MB, which leaves the pool more room.
- Built-in JIT: when it cannot run (no pairing file, unsupported iOS, a sideloaded build without its helper) it says why instead of silently opening StikDebug. A helper failure ends the 90-second wait at once, so the next tap tries again.
- Settings no longer says that StikDebug requires pairing and LocalDevVPN.
- Visual C++ x64 is installed by reading Microsoft's installer, never by running it. The installer is now downloaded to a temporary folder instead of the Windows downloads folder, where it appeared in the library and opened Microsoft's setup window (whose buttons did not take taps). An old copy left there is removed.
- Closing a game that never exits: besides Retry and Keep Waiting, the dialog offers Close iDeck. This is the only way to end a Windows game that ignores Alt+F4, since Wine runs inside iDeck; Madeira offers the same.
- EA covers fill their card in the library and in the store column, whether the game is installed, installing or not installed. EA's 9:16 pack art was fitted into the 2:3 card and looked small.
- Epic game sizes show the base game: files that carry install tags (language packs, high-resolution textures, optional modes) are no longer counted. Fortnite showed 160.62 GB.

### Settings
- The bug report no longer lists steamservice.dll (Steam's Windows service, which does not run under Wine) as missing, and shows "pool automatic" instead of "pool 0 MB".
- JIT & Debugging no longer says that JIT does not guarantee FEX is ready, and the pairing file appears only with the Built-in method, the only one that uses it.
- Download notifications is switched off and greyed out when iDeck's notifications are refused in iOS Settings.
- Hold Display at Maximum Rate appears only on screens faster than 60 Hz.
- Graphics & Performance › Advanced shows short notes, and only for choices that change something.

### JIT
- The JIT pool prepared when StikDebug attaches keeps a 256 MB executable window free instead of 128 MB, so games with a large fixed-base exe (Assassin's Creed Unity's ACU.exe, 131 MB) can still load with it. A game that needs more is named in the log.

### Initial setup
- The Windows runtime step is replaced by two steps. Visual C++ prepares the Windows environment and installs Microsoft Visual C++ 2005-2022 (x64 and x86). Wine Mono installs the .NET Framework runtime. Both are downloaded during setup, so programs no longer wait for them on first use.

- The initial setup has a new design: a numbered step bar with checks for finished steps, a card per step with its icon, grouped component rows with status badges, and full-width install buttons.

### Installer caches
- When an installer (.exe/.msi) ends, the files it unpacked into the Windows Temp folders and the WinINet download cache are deleted, freeing the space setup payloads used to keep. This runs only when no Windows program is running, and the log says how much was freed.

### Per-game JIT pool
- A game's page has a JIT pool setting under Performance (Automatic, 336–768 MB). A light game can use less memory, and a heavy one can ask for more. A pool already prepared when StikDebug attached keeps its size until iDeck is reopened.

### App size
- The IPA is built like Madeira's: the Windows runtime is inside, while Wine Mono (.NET programs) and Microsoft's Visual C++ runtimes are downloaded on the device the first time they are needed instead of being bundled.

### Memory
- Epic downloads keep at most 64 MB of reused chunks in memory (256 MB before); the rest waits on disk.
- EA downloads fetch 2 MB ranges instead of 4 MB, halving what the concurrent requests hold in memory.
- Covers and other caches iDeck rebuilds on demand are dropped when a game starts.

### Windows programs
- When an installer (.exe or .msi from the Windows downloads folder) installs something, it leaves the library and only the installed programs are shown. iDeck compares the programs with Start Menu or Desktop shortcuts before and after the installer runs. The installer file stays on disk and comes back to the list if everything it installed is removed.

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
- The first taps of a session are logged with where they were sent in the Windows screen and how they were mapped, and the bug report includes them, to find why taps on some installers' buttons do nothing.
- A crash in Wine's native code now names the image and function of the faulting address and its caller (`[bus-sym]`), instead of raw addresses only.
- The bug report has a "Missing DLLs:" line listing what the last Windows session could not find, from Wine's own messages: a DLL a program imports that is missing or failed to load, a function with no implementation, an unimplemented function that was called, and a DLL looked up in system32 or syswow64 that is not there. When there are none, the line says so.

### Release
- Updated the application version to 2.3.0 (build 72).
