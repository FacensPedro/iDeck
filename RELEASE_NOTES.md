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
