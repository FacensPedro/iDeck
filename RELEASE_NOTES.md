## What's Changed
### Library
- The Install button over a game's cover is gone: a game is installed from its page. Covers are no longer blurred for games that are not installed.
- Only games that need Easy Anti-Cheat keep a blurred cover with the struck-through install symbol in the middle.

### Game page
- The Pause and Stop buttons of a download have no background: Pause is white text, Stop is red.

### Game session
- The loading screen no longer shows how big the JIT pool ended up ("The pool is only X MB."); the size is still written to iDeck's log.

### Settings
- Download notifications switches itself off when Don't Allow is tapped in iOS's notification prompt, and turning it on asks iOS again (it stays off if notifications are refused).

### Ubisoft Connect
- Signing in to Ubisoft in iDeck works again: Ubisoft refused iDeck's old app id ("The Ubi-AppId header is invalid"). iDeck now uses Ubisoft Connect for PC's app id, tries Ubisoft's web app ids when one is refused, and keeps the accepted one for renewing the session and reading the library.

### Version
- Updated the application version to 2.11.2 (build 117).
