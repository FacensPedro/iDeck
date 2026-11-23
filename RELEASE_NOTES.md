## What's Changed
### Ubisoft Connect
- Tapping a Ubisoft game now opens its page, as for Steam, GOG, Epic and the EA app. Install, Pause, Stop and Play are on the page, with the download's progress and size.
- Download errors (failed, not signed in, anti-cheat) now appear on the game's page and under its card, as in the other stores, instead of in a pop-up.
- When Ubisoft's download service does not answer, iDeck now tries a second time over IPv4, and the error says why it could not connect (for example a name that did not resolve, a refused connection or a secure-connection problem). Each step is written to iDeck's log. Before, it only said "did not answer (connection)".

### Downloads (every store)
- When a game's download fails, iDeck now removes what it had downloaded, as Stop does, in Steam, GOG, Epic, the EA app and Ubisoft Connect. The error stays on the game's page, and Install starts again from the beginning. A game that was already installed is kept when its update fails.
- Pausing a download no longer shows "Download paused": not on the game's page, not on the Ubisoft card, and not as a notification when iOS pauses a download in the background.

### 32-bit games
- Second fix for 32-bit games that closed seconds after starting (Assassin's Creed IV Black Flag, BioShock 2). The 2.13.1 fix changed a part of Wine that the build does not recompile, so it never reached the app. The whole fix is now in the part that is recompiled.

### Library
- After StikDebug sends you back to iDeck, the library stays on the store you were using (for example the EA app) instead of switching to Steam. iDeck now remembers the last store tab you chose.

### Game session
- The "Closing Wine and wineserver..." text next to the settings button in a game is gone. The closing box below it still shows that the game is closing.
- A game that needs a larger memory area for its program (such as Dragon Age: Inquisition) now gets it on the second launch in the same iDeck run too. iDeck kept that area reserved from the first launch and then failed to reserve it again ("could NOT widen the window to 192MB"); it now reuses it.

### Steam
- Fixed BioShock 2 Remastered failing to download with "Steam's download servers would not hand out this game's file list (HTTP 401)". One of its file packs comes from another Steam app, and Steam refused it. iDeck now asks for it as part of the game itself and, if the account does not own it, installs the game without that pack.

### Visual C++
- iDeck's Visual C++ install now also includes Microsoft Visual C++ 2015-2019 (32-bit and 64-bit), alongside 2005-2013 and 2015-2022. The newer 2015-2022 files are kept where the two share a name. iDeck installs the runtimes again once to add it.

### Settings
- A game's settings on its page are saved as you change them. The blue ✓ button and the Done button are gone: close the page by swiping it down.
- Removed the note "Direct3D 11 and Direct3D 12 are chosen automatically for each game".
- CPU cores now shows "Automatic" instead of "All" by default.
- Removed the note "Notifications are turned off for iDeck in iOS Settings".
- Updates: removed the Version section (installed version, View iDeck releases, and the note about sideloading). The installed version is still shown above, and Install update appears there when an update is available.

### Wine log
- Copying the Wine log is much faster. iDeck now finds the last session from the end of the file and checks each line in place, instead of searching the whole file and converting every line to text.

### Version
- Updated the application version to 2.13.3 (build 121).
