## What's Changed
### Steam one-time installs
- A game's Microsoft Visual C++ redistributables (for example Assassin's Creed IV Black Flag's 2008 SP1 x86 and x64) are no longer run before the game. On the device they crashed or never closed, so iDeck kept saying it was installing them while nothing was installed. iDeck already puts its own Visual C++ runtimes (2005 to 2022, 32- and 64-bit) into every prefix, so the game uses those, as it already did for DirectX setup.

### Version
- Updated the application version to 2.8.1 (build 98).
