## What's Changed
### Assassin's Creed IV Black Flag
- Black Flag now gets its own recommended settings, which run Direct3D 9 on Wine's wined3d. With the default DXMT path the game closed while d3d9.dll was loading: a debug message from the d3d9 loader went back through the 32-bit exception path and the process ended before the game window opened. Reset to Recommended in the game's settings applies the list to an existing install.

### ARM64EC runtime (Steam client)
- When the loader points an import at native ARM64EC code (for example combase.dll and ole32.dll calling rpcrt4.dll's NdrClientCall2), that slot is now copied right away into the copy of the DLL that actually runs. Before, the running copy kept the old x64 thunk (the log's "POOL STALE"), so those calls went through the x64 path.
- FEX's table that maps running DLL copies back to their real address now holds 1,024 DLLs instead of 256. With the Steam client's DLLs the table filled up; DLLs left out could not be mapped, and dockhost.exe's TLS callbacks gave FEX an iOS address as the guest instruction pointer (the log's "HOST PC LEAKED INTO STATE.RIP").

### Logs
- The Wine log you copy or share repeats much less. Lines that differ only in an address or code written without 0x (for example 7ffe1a2b or c000001d) now count as the same line, so they fold into "repeated N more times" or are left out after two appearances. The summary of left-out lines at the end lists the 15 most repeated instead of 40.

### Version
- Updated the application version to 2.8.2 (build 99).
