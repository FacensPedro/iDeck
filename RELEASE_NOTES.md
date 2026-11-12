## What's Changed
### Windows runtime
- 64-bit games whose executable cannot be moved in memory and is larger than 128 MB start again (Assassin's Creed Unity's ACU.exe is 131 MB). iDeck never measured the game's executable before reserving the JIT pool, so the pool was placed where the executable must load and Windows reported "failed to create main module" (0xC0000018). The executable is now measured first, as Madeira does, for Steam, GOG, Epic Games, EA app and .exe launches, and the pool is placed above it.

### Release
- Updated the application version to 1.7.9 (build 61).
