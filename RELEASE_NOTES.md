## What's Changed
### 32-bit games
- Assassin's Creed IV no longer closes on the thread-name signal (0x406D1388). The fix in 2.15.0 was written for a part of Wine that iDeck does not use on iOS, so it never took effect. It is now in the part iDeck runs, next to the rule that already ignored debug output.

### Ubisoft Connect
- 2.15.0's connection retry works: the secure connection now opens with TLS 1.2. Ubisoft's server then ended it at once. That is how it treats a client version it no longer accepts, and iDeck always sent the same fixed version number. iDeck now sends the version of the Ubisoft Connect it installs, when that is newer. The version used is written to the log, and so is whether the server answered anything before ending the connection.

### Game details
- Launch and Uninstall are now the same size as the Install button.

### Version
- Updated the application version to 2.15.1 (build 123).
