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
