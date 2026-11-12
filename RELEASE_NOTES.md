## What's Changed
### Windows runtime
- The x64 Windows runtime is now compiled from the same patched Wine as the x86 one: all 386 of its Wine modules, instead of Madeira's prebuilt copies. The Wine Staging and GE-Proton patches and iDeck's own Wine fixes now reach 64-bit games too. Direct3D (DXMT and Madeira's D3D12), FEX and Madeira's own modules are unchanged.
- The DirectShow, Media Foundation and installer modules added in 1.8.2 are now built the way Madeira builds its modules, with their delayed imports linked directly: an x64 delay-load stub can fault when the module runs from the JIT pool.

### Bugs & logs
- The Wine log (madeira-log.txt) is no longer kept growing across every session: between sessions, once it passes 24 MB it becomes madeira-log.previous.txt and a new one starts. The full log of each session is still written to disk as it happens, so it survives a crash.

### Starting another game
- When a game has just closed, iDeck now waits up to 20 seconds for it to finish shutting down, showing "Waiting for the previous Windows session to finish…", instead of 5.
- If it still does not finish, the message now says that iDeck has to be reopened, and how. Retrying did not help: Wine runs inside iDeck, so only a new launch of the app resets it.

### JIT memory
- When the JIT pool has to shrink below 500 MB (the address space is fragmented by an earlier session), the loading screen now says so and suggests reopening iDeck. Until now this warning was only in the log.

### Build
- iDeck's patches to Madeira are applied from one list (patches/series.txt) by one tested script, instead of twenty copies of the same shell block. A patch that no longer fits the pinned sources stops the build with its name.

### Release
- Updated the application version to 1.8.5 (build 67).
