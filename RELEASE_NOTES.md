## What's Changed
### Ubisoft Connect
- Ubisoft games download again when Ubisoft's download service closes the secure connection right away (the error "server closed session with no notification"). iDeck now tries a second time with the older secure-connection version (TLS 1.2), then a third time over IPv4. Each try is written to iDeck's log.

### 32-bit games
- The 2.14.0 fix works: Assassin's Creed IV no longer closes on the window-callback error. It now got further and closed on a different signal: a thread-name message (0x406D1388) that games send for debuggers and catch themselves. In iOS's 32-bit mode the game's own catch was not reached, so Wine ended the game. Wine now ignores these debugger-only messages (thread names and debug output) when nothing catches them, as Windows without a debugger effectively does.
- Duke Nukem 3D: 20th Anniversary World Tour, Overcooked and Max Payne 2 no longer close a few seconds after starting. When a 32-bit game's window returned from a message, three of the Windows runtime's registers were not restored, and one of them was then used to write into memory. That broke the game's window message code (a crash in wow64win.dll, then a stack overflow). All of them are now restored. Other 32-bit games that closed by themselves right after opening their window may be fixed too.

### Games that closed iDeck or did not start
- Overcooked: Gourmet Edition (GOG) closed iDeck a few seconds after starting. The game writes into memory next to its own code, and the x86 translator kept handling the same write again until iDeck stopped. When a game's log shows this, iDeck now turns on the "Compatible" code checks for that game, which avoid the loop, from its next start. A game whose Code checks setting was chosen by hand keeps it.
- Burnout Paradise Remastered did not start: "No safe address range can hold the Wine JIT pool". The largest free memory area was 564 MB for a 560 MB pool, but its safe part was smaller, and iDeck gave up instead of using a slightly smaller pool. It now shrinks the pool to the largest safe area, as it already did when no area was large enough.

### Steam
- Game sizes are right again for games that also have content for Steam China, such as Delta Force (219.65 GB shown before; the game is about 88 GB). Steam China's copies of the game files were counted, and downloaded, with the global ones. They are now left out, as Steam itself does.
- Optional content Steam adds only for owners of a DLC is no longer counted or downloaded without that DLC.

### EA app
- When an EA game refuses its licence and opens EA's activation window (Dragon Age: Inquisition), iDeck's log now shows the last lines that window wrote about why. Before, the reason was only in a bug report. Addresses, e-mails, tokens and account names are removed from those lines.

### Game session
- The FPS, CPU, GPU memory and frame time figures now sit inside the black strip above the game, in one left-aligned column, instead of hanging over the game image. "GPU memory (Metal)" is now "GPU memory".
- The minimize button for the close and settings buttons now stays in the same place when they are minimized. Before, it moved up.
- Every game now starts with those buttons minimized. Before, expanding them once kept them expanded in every later game.

### Game details
- Launch and Uninstall are side by side.
- Uninstalling a game asks first in a pop-up, on every store's page, Steam included.
- The Install button is smaller.

### Version
- Updated the application version to 2.14.1 (build 122).
