## What's Changed
### 32-bit games
- Assassin's Creed IV no longer closes on the thread-name signal (0x406D1388). The fix in 2.15.0 was written for a part of Wine that iDeck does not use on iOS, so it never took effect. It is now in the part iDeck runs, next to the rule that already ignored debug output.

### Steam
- Dark Souls Remastered starts again. Its program asks Windows to place it at a random address but carries no information for moving it, so Windows loads it at its usual address instead. Wine on iOS moved it anyway, and the game stopped before it opened ("failed to create main module", 0xC0000018). Programs like this now stay at their usual address.

### Ubisoft Connect
- 2.15.0's connection retry works: the secure connection now opens with TLS 1.2. Ubisoft's server then ended it at once. That is how it treats a client version it no longer accepts, and iDeck always sent the same fixed version number. iDeck now sends the version of the Ubisoft Connect it installs, when that is newer. The version used is written to the log, and so is whether the server answered anything before ending the connection.

### EA app
- The text of EA's activation window log is now readable in iDeck's log. It was written as "L i c e n s e" and cut off after its first lines, before the reason. The whole log (up to 60 lines) is now kept.
- Dragon Age: Inquisition no longer fails with an address conflict (0xC0000018) when started right after a long download. A download in the same iDeck process could take part of the memory area the game's program needs. iDeck now checks that area before starting a game, and reopens itself first when it is taken.

### DLL check
- The DLL check no longer reports a DLL as missing when the game loads it from one of its own subfolders. EA app games named "core/activation64.dll", which is there, in their error message.

### Game details
- Launch and Uninstall are now the same size as the Install button.

### Version
- Updated the application version to 2.15.1 (build 123).
