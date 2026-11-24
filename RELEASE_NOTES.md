## What's Changed
### Ubisoft Connect
- Ubisoft games download again when Ubisoft's download service closes the secure connection right away (the error "server closed session with no notification"). iDeck now tries a second time with the older secure-connection version (TLS 1.2), then a third time over IPv4. Each try is written to iDeck's log.

### 32-bit games
- The 2.14.0 fix works: Assassin's Creed IV no longer closes on the window-callback error. It now got further and closed on a different signal: a thread-name message (0x406D1388) that games send for debuggers and catch themselves. In iOS's 32-bit mode the game's own catch was not reached, so Wine ended the game. Wine now ignores these debugger-only messages (thread names and debug output) when nothing catches them, as Windows without a debugger effectively does.
- Duke Nukem 3D: 20th Anniversary World Tour, Overcooked and Max Payne 2 no longer close a few seconds after starting. When a 32-bit game's window returned from a message, three of the Windows runtime's registers were not restored, and one of them was then used to write into memory. That broke the game's window message code (a crash in wow64win.dll, then a stack overflow). All of them are now restored. Other 32-bit games that closed by themselves right after opening their window may be fixed too.

### Memory
- iDeck now notices when iOS closes it for lack of memory during a game. RAM is checked every 5 seconds while a game runs, and when iDeck opens again with very little memory left at the last check, the stop is recorded for that game.
- That game's next start uses lighter memory settings (one frame in flight instead of two).
- After two such stops in a row, iDeck asks before starting the game again: lower its resolution or close other apps. Starting it again within 3 minutes goes ahead anyway. A normal exit clears the count.

### Games that closed iDeck or did not start
- Overcooked: Gourmet Edition (GOG) closed iDeck a few seconds after starting. The game writes into memory next to its own code, and the x86 translator kept handling the same write again until iDeck stopped. When a game's log shows this, iDeck now turns on the "Compatible" code checks for that game, which avoid the loop, from its next start. A game whose Code checks setting was chosen by hand keeps it.
- Burnout Paradise Remastered did not start: "No safe address range can hold the Wine JIT pool". The largest free memory area was 564 MB for a 560 MB pool, but its safe part was smaller, and iDeck gave up instead of using a slightly smaller pool. It now shrinks the pool to the largest safe area, as it already did when no area was large enough.

### Steam
- Steam games start with Steam's own launch settings again (program, arguments and working folder). iDeck reopens in a fresh process for each game, and there the library came from a saved snapshot without those settings, so iDeck guessed the program from the game's files ("Steam metadata did not resolve" in the log). The snapshot now keeps them.
- A Steam game started without Steam's client that asks for Steam and closes now shows a specific message. iDeck starts it through Steam's Windows client from then on.
- Game sizes are right again for games that also have content for Steam China, such as Delta Force (219.65 GB shown before; the game is about 88 GB). Steam China's copies of the game files were counted, and downloaded, with the global ones. They are now left out, as Steam itself does.
- Optional content Steam adds only for owners of a DLC is no longer counted or downloaded without that DLC.

### EA app
- When an EA game refuses its licence and opens EA's activation window (Dragon Age: Inquisition), iDeck's log now shows the last lines that window wrote about why. Before, the reason was only in a bug report. Addresses, e-mails, tokens and account names are removed from those lines.

### Game session
- The FPS, CPU, GPU memory and frame time figures now sit inside the black strip above the game, in one left-aligned column, instead of hanging over the game image. "GPU memory (Metal)" is now "GPU memory".
- The minimize button for the close and settings buttons now stays in the same place when they are minimized. Before, it moved up.
- Every game now starts with those buttons minimized. Before, expanding them once kept them expanded in every later game.

### Windows sessions
- While a game runs, if it shows no new image for 20 seconds after it had started drawing, the bar at the top says the game may be frozen and that it can be closed with X. The message goes away when images arrive again. Both moments are written to iDeck's log.
- After a game session, Windows' temporary folders (C:\windows\temp and each user's Temp folder) are emptied of what earlier sessions left there. Files from the session that just ended stay until the next cleanup, so an installer that continues later still finds them.

### Game details
- Launch and Uninstall are side by side.
- Uninstalling a game asks first in a pop-up, on every store's page, Steam included.
- The Install button is smaller.

### Version
- Updated the application version to 2.14.1 (build 122).
