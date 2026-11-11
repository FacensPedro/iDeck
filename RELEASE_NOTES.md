## What's Changed
### Downloads
- GOG: the chunks of a file are fetched three at a time and written in order. A game that is one large archive used to download one chunk at a time.
- Steam: 16 chunk requests at once instead of 8, with as many connections to a content server.
- Epic Games: 32 chunks fetched ahead of the writer instead of 24.
- EA app: 16 ranges of a large file at once instead of 12, over up to 40 connections.

### Bugs & logs
- Logs are always detailed: every session records Wine's and Madeira's full error output. The Detailed diagnostics switch is gone. The tools that slowed games down when that switch was on (the thread sampler and the JIT dump) stay off.
- A copied bug report starts with the build commit and graphics profile, physical memory and the memory iOS still allows, the Memory+ state, the JIT method and pool size, whether the x64 and x86 Windows runtimes are installed, the device language and free storage.
- Up to 600 distinct problems per log are listed instead of 300.

### Madeira Dock
- The Dock's report file is read and parsed only when it changed, not every second.

### Release
- Updated the application version to 1.7.4 (build 56).
