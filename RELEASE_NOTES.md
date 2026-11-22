## What's Changed
### Stores
- Fixed the EA app and Ubisoft Connect background install failing with "Metal display surface did not become ready. Wine was not started.": Wine now gets a hidden Metal surface while the launchers install, so its screen still never opens.
- The initial setup no longer installs the EA app and Ubisoft Connect by itself: they install when Install is tapped. The step's description no longer says they install automatically.
- While the launchers install, the initial setup shows "Installing EA app / Ubisoft Connect..." instead of the Visual C++ step's text.

### JIT
- The small pool notice is shorter: "The pool is only X MB."
- The JIT pool is freed automatically when an installer finishes or is stopped and when a game closes.

### Windows programs
- After an .exe installer finishes, it leaves the list by the stores as soon as Wine stops (also for .msi installers).
- Programs an installer put in the prefix use the name of the shortcut it created (Tor Browser, not firefox).
- Programs installed while iDeck runs get their cover (their own icon) right away.

### Version
- Updated the application version to 2.10.7 (build 115).
