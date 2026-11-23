## What's Changed
### Ubisoft Connect
- Ubisoft games download again when Ubisoft's download service closes the secure connection right away (the error "server closed session with no notification"). iDeck now tries a second time with the older secure-connection version (TLS 1.2), then a third time over IPv4. Each try is written to iDeck's log.

### 32-bit games
- The 2.14.0 fix works: Assassin's Creed IV no longer closes on the window-callback error. It now got further and closed on a different signal: a thread-name message (0x406D1388) that games send for debuggers and catch themselves. In iOS's 32-bit mode the game's own catch was not reached, so Wine ended the game. Wine now ignores these debugger-only messages (thread names and debug output) when nothing catches them, as Windows without a debugger effectively does.

### Version
- Updated the application version to 2.14.1 (build 122).
