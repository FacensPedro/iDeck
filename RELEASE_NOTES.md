## What's Changed
### Games
- Bethesda games start the game itself: Fallout: New Vegas, Fallout 3, Fallout 4, Skyrim (original, Special Edition and VR), Oblivion and Morrowind skip their launcher, which under Wine stopped at "Detecting Video Hardware" or closed when Play was tapped. The games write their default settings themselves on the first start.
- Fixed Fallout: New Vegas from Epic Games closing about 25 seconds into the game (error 0xC000001D). A read of the game's own memory, made while it reported a message, hit memory that had already been freed; on iOS that fault landed in the middle of a system call and broke its return. The read now goes through the kernel, which reports unreadable memory instead of faulting, and copies whatever is readable, as Windows does.
- DOOM (2016): the game asks for OpenGL 4.5 core, which the OpenGL runtime on iOS does not reach, and stopped with "wglCreateContextAttribsARB failed". iDeck now starts the game's own Vulkan build (DOOMx64vk.exe), which runs on MoltenVK, when it is in the game folder and Vulkan is not turned off for the game.
- Mafia: Definitive Edition (GOG): GOG's play task opened 2K's launcher, which stops with exit code 1 under Wine before the game starts. iDeck now starts the game's own executable. Other GOG games whose play task is only a publisher launcher use another play task of the game, never a setup, settings or uninstall tool.

### Dragon Age: Inquisition
- The game hands its licence check to EA's activation program (ActivationUI.exe, 32-bit). In the earlier Wine logs it crashed when it opened its window, at the same point already fixed for other 32-bit games' windows. The crash in 3.0 happens later, and its Wine log was gone: the log is cut once it passes 8 MB, and four more sessions ran before the report.
- The Wine log of the last launch that failed is now kept on its own (madeira-log.failed.txt), whatever runs after it. Bugs & logs has "Copy Wine log of the last failed launch", with personal data removed as in the other logs.
- The iDeck log keeps every row EA's activation program writes, not only the first two.

### Ubisoft Connect
- Installer integrity: every slice is checked against the SHA-1 it is named by and downloaded again (up to four times) when it does not match. A file whose slices do not add up to its size stops the install instead of being padded with zeros. When a download resumes, a file in the journal counts as installed only while it is on disk at its full size, so a file cut short or deleted since is downloaded again.

### Auto DLL Manager
- Every DLL taken from Microsoft's package is checked to be a Windows DLL of the right architecture, after extraction and after the copy into the game folder. A damaged cache is dropped and downloaded again.
- Better detection: delay-loaded imports are read too (games often load D3DX and the HLSL compiler that way). D3DX 9/10/11, the HLSL compiler and D3DCSX are looked up in Wine's folders instead of being assumed present. A start that fails now also names its missing DLLs through Wine's own "not found" lines.

### Session lifecycle
- Each state change records how long the previous state lasted, in the log and the bug report. A session stuck in preparing (3 min), launching (2 min), closing (45 s) or recovering (1 min) is noted once in the log. "Freeing memory" before a launch (iDeck reopening through StikDebug) is now a state change instead of being ignored.

### Resource Governor
- The governor now controls four domains on their own, each Auto, Economy or Performance (Settings › Graphics & Performance › Resource Governor). A game's own page always wins.
  - FEX: Economy shows the game at most 4 cores and uses the faster x87 maths; Performance uses the faster x87 maths with every core.
  - JIT: Economy asks for a 384 MB pool, Performance for 560 MB, for games whose page leaves the size to iDeck.
  - GPU: Economy runs one frame in flight and turns frame generation off; Performance keeps two frames in flight unless less than 2 GB is free.
  - Sessions: Economy hands memory back before the launch, pauses every store's downloads while the game runs (they go on when it ends) and pauses the game in the background; Performance keeps the game running in the background.
- Auto acts as Economy in Low Power Mode or when the device is hot, and for JIT and GPU when less than 3 GB is free. Each launch logs its plan, and the bug report shows it.

### Stores
- A shared StoreProvider for Steam, GOG, Epic Games, the EA app and Ubisoft Connect: one interface for sign-in, owned games, install state, downloads (queued, running, paused, failed), install, pause, resume, stop, uninstall and refresh. The Resource Governor, the memory log and Bugs & logs use it. "Clear logs" now also waits for the EA app's and Ubisoft's downloads, which it did not count before. The bug report lists each store's sign-in, games and downloads (counts only).

### Version
- Updated the application version to 3.0.1 (build 130).
