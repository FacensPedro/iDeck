## What's Changed
### Ubisoft Connect
- Ubisoft games show their cover in the library again. Ubisoft's account service gives only the game names, so iDeck finds the same game in Steam's store and uses its portrait cover. Each cover is looked up once and remembered.

### Tor Browser and Firefox
- Firefox's sandbox is turned off under Wine, so Tor Browser's tabs and helper processes can start. Wine refused the sandbox's way of starting them. Every launch sets Mozilla's switches that turn the sandboxes off, and Tor Browser's profile gets a user.js with the sandbox off and fewer helper processes.

### Game session
- Fixed iDeck crashing a few seconds after a game closed: a part of Wine kept reading the game's JIT memory after iDeck had freed it. It now stops before the memory is freed.
- When a download finishes while iDeck is in the background and a game is started, iDeck now waits until it is back in front to open StikDebug. Before, iOS refused and iDeck wrongly said StikDebug was not installed.

### Version
- Updated the application version to 2.12.1 (build 118).
