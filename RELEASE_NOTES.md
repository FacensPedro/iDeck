## What's Changed
### Windows games on iOS 26 (iPhone without iOS 27)
- Fixed the crash right after Wine connected to wineserver on iOS 26 ("wineserver stopped unexpectedly", last stage "Wine started" or "Installing Steam prerequisites"). Wine was built for an SDK that has `pipe2` (iOS 27); on iOS 26 that function does not exist, its import is empty, and the first call jumped to address 0. The `[ideck-fault]` line from 2.7.5 showed it (`pc=0x0`, `esr=0x82000006`). Wine now checks that `pipe2` exists and otherwise uses `pipe`.

### Download buttons
- **Pause download** and **Stop download** have the same fixed size on every store's game page (Steam, GOG, Epic Games, EA app), and so do **Resume** and **Stop download** on a paused download. Long labels stay on one line and shrink slightly instead of wrapping.

### EA app and Ubisoft games, as GOG games
- EA app: a licence iDeck cannot prepare (no content id, or EA refusing a renewal of an outdated licence) no longer stops the launch with a licence error. As a GOG game runs offline when iDeck cannot answer as GOG Galaxy, the game now starts and its own activation decides.
- Ubisoft games on Steam: iDeck no longer runs the Ubisoft Connect installer among the one-time installs. It is left out as GOG Galaxy is, and the game starts without it (a game that requires Ubisoft Connect can still stop at its own start).

### Bug reports
- The `[ideck-fault]` line (faulting address, PC, LR, ESR and FAR of a Wine crash on iOS) now appears in the bug report; it was logged but left out of the report.

### Builds
- Faster IPA builds after a Wine patch: a patch to the wineserver or to a DLL's unix side no longer recompiles the 719 32-bit Wine modules, and the pinned Madeira sources come from a cache instead of being fetched again.

### Version
- Updated the application version to 2.7.7 (build 97).
