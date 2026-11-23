## What's Changed
### Ubisoft Connect
- The Ubisoft library loads again after signing in. Version 2.13.0 waited for Ubisoft's download service before showing any game, and that connection could wait forever, so the page stayed on "loading". The account's games now appear as soon as Ubisoft lists them, and the download information follows in the background.
- Signing in or out in Settings now updates the Ubisoft page right away, without reopening iDeck.
- An expired Ubisoft session is renewed automatically when the library loads. If it cannot be renewed, the page asks to sign in again.
- If the connection to Ubisoft's download service does not open within 20 seconds, iDeck stops waiting: the games already listed stay on the page, and the reason goes to iDeck's log.
- The Ubisoft sign-in now stays saved like Steam, GOG, Epic and EA: it is kept in the device's Keychain, which iOS keeps even when iDeck is deleted, and only Sign out removes it. Before, iDeck deleted the account by itself when Ubisoft refused to renew the session. Now the account stays, and Settings offers "Sign in again" to update it.
- The sign-in screen no longer has the "Ubisoft account" button that opened Safari. Signing in happens only inside iDeck.

### Game session
- Closing a game no longer opens StikDebug by itself. Before, iDeck reopened itself through StikDebug as soon as Wine closed. Now StikDebug opens only when you start the next game and iDeck needs a fresh process for it.
- The X button now only closes the game. If the game does not exit, the usual warning appears, with Retry and Close iDeck. Close iDeck now just closes it, without opening StikDebug.
- Removed the note under the Wine log buttons that said which data is removed from logs. Copied and shared logs still have passwords, account names, e-mail and IP addresses removed.

### 32-bit games
- Fixed 32-bit games closing a few seconds after they start, such as BioShock 2. When the game created its first window, Wine's return from the window's callback tried to walk back through the translated game code, which it cannot do. It kept trying until it ran out of stack, and the game closed. That return now jumps straight back.

### Wine log
- The Wine log is much smaller. A setting iDeck turned on made Wine record every system call and file access, about 16 MB and 220,000 lines for a single session. iDeck now logs Wine's errors and the programs each session starts and loads, which is what Bugs & logs reads.
- A copied or shared Wine log is now a short version:
  - only the last session;
  - no system-call and file trace lines (their count is noted at the top);
  - lines longer than 400 characters cut;
  - repeated lines folded;
  - at most 256 KB, keeping the session's start and its end.

### Settings
- "Madeira native" no longer appears on the Windows runtime row in Settings. It is shown only on that page, as the IPA runtime.

### Version
- Updated the application version to 2.13.1 (build 119).
