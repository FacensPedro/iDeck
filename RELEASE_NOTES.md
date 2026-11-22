## What's Changed
### Stores
- The EA app and Ubisoft Connect install without Wine and without JIT: iDeck downloads the official installers and copies their files on the device (Ubisoft Connect's NSIS installer, the EA app's Windows Installer package), then writes their registry values. No Windows program runs, so the "Metal display surface did not become ready" error and the StikDebug request are gone from this install.
- The initial setup no longer installs the EA app and Ubisoft Connect by itself: they install when Install is tapped. The step's description no longer says they install automatically.
- While the launchers install, the initial setup shows "Installing EA app / Ubisoft Connect..." instead of the Visual C++ step's text.

### Library
- The Install button on a game's cover is a small capsule at the bottom of the cover, and "Cannot install" (Easy Anti-Cheat) uses the same capsule: the artwork stays visible.
- After an .exe installer finishes, it leaves the list by the stores as soon as Wine stops (also for .msi installers).
- Programs an installer put in the prefix use the name of the shortcut it created (Tor Browser, not firefox).
- Programs installed while iDeck runs get their cover (their own icon) right away.

### Privacy
- iDeck's log, copied bugs and copied or shared Wine logs no longer contain passwords, tokens, account names, e-mail addresses, IP addresses or the Windows user folder's name.
- Copying the Wine log is fast again: the privacy filter runs once over the text and skips the checks the log does not need.

### Controls
- The Windows controller API that follows the connected controller is now called "Automatic".

### JIT
- The small pool notice is shorter: "The pool is only X MB."
- The JIT pool is freed automatically when an installer finishes or is stopped and when a game closes.

### Version
- Updated the application version to 2.11.0 (build 115).
