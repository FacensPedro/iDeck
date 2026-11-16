## What's Changed
### Assassin's Creed IV Black Flag
- Black Flag now gets its own recommended settings, which run Direct3D 9 on Wine's wined3d. With the default DXMT path the game closed while d3d9.dll was loading: a debug message from the d3d9 loader went back through the 32-bit exception path and the process ended before the game window opened. Reset to Recommended in the game's settings applies the list to an existing install.

### Version
- Updated the application version to 2.8.2 (build 99).
