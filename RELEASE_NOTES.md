## What's Changed
### Ubisoft Connect
- Ubisoft games now install from the library, like the other stores: tap a game that is not installed and iDeck downloads it straight from Ubisoft's servers. If Ubisoft Connect is not installed yet, it is installed first. A progress bar shows on the cover. Tap the cover to pause or resume, and long-press it to stop the download and remove the files. The game uses the device's language when Ubisoft has it, otherwise English. Signing in to Ubisoft in Settings is required.
- iDeck now reads every compression Ubisoft uses for game files: zlib, Zstandard and LZHAM. Games packed with LZHAM install too, instead of stopping with "this game uses a compression iDeck cannot read yet".
- Ubisoft games show their cover in the library again. Ubisoft's account service gives only the game names, so iDeck finds the same game in Steam's store and uses its portrait cover. Each cover is looked up once and remembered.

### Tor Browser and Firefox
- Firefox's sandbox is turned off under Wine, so Tor Browser's tabs and helper processes can start. Wine refused the sandbox's way of starting them. Every launch sets Mozilla's switches that turn the sandboxes off, and Tor Browser's profile gets a user.js with the sandbox off and fewer helper processes.

### Windows programs
- Uninstall now works for programs installed with a .exe installer (such as Tor Browser): iDeck removes the program's own folder and its Start Menu and Desktop shortcuts. Before, it refused with "iDeck refused to remove a file outside its Windows library". Folders shared by many programs (Program Files, the Desktop, Windows, store folders) are never removed whole, and nothing is removed while a Windows program is running.

### Game session
- Fixed iDeck crashing a few seconds after a game closed: a part of Wine kept reading the game's JIT memory after iDeck had freed it. It now stops before the memory is freed.
- Games whose executable needs a larger memory window (such as BioShock 2) no longer get a smaller JIT pool after iDeck reopens ("SMALL JIT POOL (496MB)"): the pool now continues past the area iOS keeps for iDeck's main thread, as it already did for Dragon Age: Inquisition. `pool-split = 0` in a game's settings turns this off.
- The "iOS did not exempt the JIT pool from the app's memory limit" warning appeared on every launch, although iOS never grants that exemption to apps outside Apple and iDeck still had more than 5 GB free. It now appears only when less than 2 GB is left with the pool counted.
- When a download finishes while iDeck is in the background and a game is started, iDeck now waits until it is back in front to open StikDebug. Before, iOS refused and iDeck wrongly said StikDebug was not installed.

### Version
- Updated the application version to 2.13.0 (build 118).
