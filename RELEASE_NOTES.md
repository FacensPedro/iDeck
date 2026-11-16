## What's Changed
### Assassin's Creed IV Black Flag
- Black Flag now gets its own recommended settings, which run Direct3D 9 on Wine's wined3d. With the default DXMT path the game closed while d3d9.dll was loading: a debug message from the d3d9 loader went back through the 32-bit exception path and the process ended before the game window opened. Reset to Recommended in the game's settings applies the list to an existing install.

### Logs
- The Wine log you copy or share repeats much less. Lines that differ only in an address or code written without 0x (for example 7ffe1a2b or c000001d) now count as the same line, so they fold into "repeated N more times" or are left out after two appearances. The summary of left-out lines at the end lists the 15 most repeated instead of 40.

### Version
- Updated the application version to 2.8.2 (build 99).
