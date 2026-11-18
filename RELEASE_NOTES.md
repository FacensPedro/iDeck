## What's Changed
### Ubisoft Connect and EA app
- The IPA is smaller: Ubisoft Connect's and the EA app's installers are no longer inside it. Each one is downloaded from Ubisoft or EA when you tap Install in Settings › Stores & launchers, and nothing installs them on its own any more.
- Ubisoft Connect now has its own page in Stores & launchers, like the other stores, instead of a blue web link.
- iDeck now recognizes an installed Ubisoft Connect: it looks where the installer recorded it and in both Program Files folders.
- After Ubisoft Connect is installed, a Ubisoft game uses it at its first start.
- The Ubisoft Connect tile in the store bar has the same background as the other stores.

### Wine runtime
- iDeck no longer tries to map address 0 at start-up (eight attempts that iOS always refused). The Mach handler already covers it.
- The search for free memory now starts above the addresses iOS never allows, which removes about 1,200 failed tries per DLL load.
- FEX's config files (`Config.json` and the per-program files) are created in `C:\ProgramData\fex-emu`, so FEX no longer fails to open them at each start.

### Downloads
- iPhones and iPads with 6 GB of RAM or less no longer overheat while downloading. The same number of chunks is still downloaded at once, so the speed does not change, but at most two are decompressed and checked at the same time instead of all of them. Devices with 8 GB or more are unchanged.

### Game screen
- On iPhones the game now fills the whole height of the screen once it shows its first frame. The close and settings buttons move to the free bar at the side of the picture instead of taking a strip at the top.
- Games that do not draw through DXMT (for example DOOM + DOOM II) are now seen as running: the loading bar and the "no game frame" warnings no longer stay on screen around the game.

### Interface
- The download buttons are shorter. In Portuguese they now read "Pausar" and "Parar"; in English "Pause" and "Stop", in Spanish "Pausar" and "Detener".

### Version
- Updated the application version to 2.9.2 (build 103).
