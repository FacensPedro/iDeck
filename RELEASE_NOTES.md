## What's Changed
### Controllers
- New default controller API, "By controller": a DualSense or DualShock 4 reaches the game as a DualSense over HID; an Xbox One/Series, Xbox 360-style or other pad as an Xbox controller (XInput).
- DualSense and DualShock 4 over HID now send touchpad finger positions and motion (gyro and accelerometer), not only the touchpad click.
- Settings shows the connected controller's family (DualSense, DualShock 4, Xbox One / Series, Xbox 360).

### EA app
- A game that closes by itself keeps the session screen open with the reason: licence refused, anti-cheat, EA app client required, missing DLL, or how many seconds after starting it stopped.
- Faster downloads: 16 files at once (was 12), 24 ranges per large file (was 16), 128 connections (was 80), 32 ranges in flight (was 28).

### Stability
- iDeck no longer crashes when a Windows session ends: the date formatter used for the session memory record (and other time stamps) is made once when iDeck opens, instead of after Wine, where ICU read a locale left behind by the finished Wine thread.

### Initial setup
- Continue on the Madeira Dock step waits until the Steam DLLs are installed, not only the Steam client.

### Memory+
- When Extended Virtual Addressing is missing, the log names the address limit iOS gave iDeck and whether the signing profile carries the entitlement.

### Logs
- Wine no longer writes the err:ole and err:winediag lines it repeats on every COM call; copied logs keep a line at most twice.

### Builds
- The IPA now carries iDeck's entitlements in its executables (ad-hoc signature). iloader, SideStore, AltStore and Sideloadly read them to enable Extended Virtual Addressing and Increased Memory Limit on the App ID; the unsigned IPA asked for neither.
- Every IPA built by iOS Build includes the Madeira runtime and Wine Mono: the Require Madeira runtime and Wine Mono options are gone, and so is Settings' note about Wine Mono not being included.

### Release
- Updated the application version to 2.7.0 (build 90).

## What's Changed
### Memory+
- Extended Virtual Addressing shows Active after iDeck is installed again with Memory+: iDeck now reads the address limit iOS gives it (and the signing profile) instead of only probing an address that the early JIT reservation may already hold.
- The Memory+ settings no longer carry the long explanation and GetMoreRam steps; the status, App ID and GetMoreRam link stay.

### Logs
- Logs are smaller and less repetitive: copied Wine logs, the bug report and the iDeck log fold lines that repeat apart from numbers, addresses and times, and list the most repeated ones once with a count.
- The Wine log is kept at 8 MB (was 24 MB); the previous one is stored compacted and compressed (madeira-log.previous.txt.lzfse). The iDeck log keeps 512 KB (was 1 MB).

### Touch
- Taps work in .exe and .msi installers: their dialogs are mapped onto the whole Windows desktop instead of a game window's area, and a tap before the game surface exists is no longer dropped.

### Interface
- Initial setup: Madeira Dock is required, and its "optional" note is gone. Settings calls it Initial setup.
- Epic Games' logo in Settings › Stores and launchers sits on black.
- iPhone in portrait: the shelf with the stores and installed or installing games is smaller, so five tiles fit on a 6.1" or smaller screen.

### Release
- Updated the application version to 2.6.0 (build 89).

## What's Changed
### JIT memory
- The automatic JIT pool grows to 640, 768 or 896 MB when iOS leaves 5, 6 or 8 GB free and the extended address space is there (and the game has no recent crash). The allocator still shrinks it to the largest free area.

### Downloads
- Steam: 72 chunks in flight (was 48), 96 connections per content server (was 64) and 8 content servers in the pool (was 6).
- EA app: 12 files at once (was 10), 80 CDN connections (was 56) and 28 range requests in flight (was 20).

### Initial setup
- The JIT step no longer shows a check before a method (StikDebug or Built-in) is chosen.

### Release
- Updated the application version to 2.5.3 (build 88).

## What's Changed
### EA app games
- A game that read its licence and still opened EA's activation window (Dragon Age: Inquisition) asked for a licence bound to the display adapter, which Wine registers only after the game has checked its licence. iDeck now notices when a game opens the activation window and asks for the licence without the adapter at the next launch, so the licence follows the machine identity the game really computes.

### JIT memory
- The executable window at 0x140000000 is held from the moment iDeck opens when the runtime did not hold it already, together with the space above it, so downloads and other work before the first game can no longer take it. Games with a large fixed-base program get their wider window again, and the JIT pool is no longer split into pieces too small for it.
- Dragon Age: Inquisition's recommended settings split the JIT pool across the two free areas above the window (as Dark Souls III does), instead of shrinking it to 496 MB.
- When the JIT pool has to shrink, the bug report shows the free memory areas it had to choose from.

### Downloads
- GOG install progress never goes backwards: late updates from parallel files are ignored.

### Cleanup
- Removed functions nothing called (an old Visual C++ setup path and unused JIT, Epic and installer helpers).

### Release
- Updated the application version to 2.5.2 (build 87).

## What's Changed
### Windows sessions
- Closing a game cancels any launch still waiting for JIT, and a launch is refused while the previous session is closing or Wine is running, so JIT preparation, launch and shutdown no longer overlap.
- Every session records iDeck's RAM at the end, its peak, the memory still available and why it ended; the last sessions appear in Bugs & logs.
- iDeck learns a compatibility profile for each game (sessions, crashes, peak memory, the JIT pool that last worked) and uses it for the automatic JIT pool.

### Performance
- Wine no longer writes its repeated fixme/warn lines; the log is scanned in chunks instead of as one large text.
- GOG Galaxy, Madeira Dock leftovers and caches are released after every session, including when a game exits by itself.
- The automatic JIT pool fits the available memory and address space.
- The JIT pool list, the bundled Visual C++ runtime and a game's library requirements are no longer checked again on every launch.

### Downloads (2.5.1)
- The library no longer stutters while games install: a download's progress reaches the interface at most twice a second (and at once when its phase changes or it finishes), instead of after every chunk. The EA app was the worst affected, then Steam, Epic Games and GOG.
- Steam downloads start sooner: every depot's key and content-server authorization are requested together before the file lists are read.
- Epic Games downloads start sooner: the installed build's file list is read while the new manifest downloads.

### Easy Anti-Cheat games
- Games that need Easy Anti-Cheat (Fortnite, Fall Guys, STAR WARS: Squadrons, Rocket League, Apex Legends and others) cannot be installed from any store: their cover shows the download symbol struck through, and their page shows a grey, disabled button saying why. Titles with an edition after the name are recognised too.

### Release
- Updated the application version to 2.5.1 (build 86).

## What's Changed
### Bugs & logs
- Copy bug report as .txt: the whole report, with every bug and every evidence section, as a text file to paste or share.
- The report says how the last game session ended (the game exited normally, an error and its reason, closed with the X, or iDeck itself stopped while the game ran) and the last stage it reached (preparing Wine, installing prerequisites, running).
- For Steam games, the report lists each prerequisite Steam's install scripts ran for the last game, with its result: installed, failed with its exit code, unfinished or not started.
- When a game crashes, the report names the exception, its address and the module it was in, taken from the Wine log.

### BioShock and other DirectX 9 games
- BioShock crashed right after one of its shaders failed to compile with Wine's D3DX (the game writes it to ShaderErrors\CompileError00001.hlsl, then reads a shader it never got). Such a game now gets Microsoft's own D3DX 9 and HLSL compiler, from Microsoft's DirectX End-User Runtime (about 95 MB, downloaded once), placed next to the game's program and used for that program only. BioShock gets them from its first start; any other game gets them after a session in which its shaders failed to compile.

### Release
- Updated the application version to 2.4.5 (build 84).
