## What's Changed
### Ubisoft Connect
- The Ubisoft library loads again after signing in. Version 2.13.0 waited for Ubisoft's download service before showing any game, and that connection could wait forever, so the page stayed on "loading". The account's games now appear as soon as Ubisoft lists them, and the download information follows in the background.
- Signing in or out in Settings now updates the Ubisoft page right away, without reopening iDeck.
- An expired Ubisoft session is renewed automatically when the library loads. If it cannot be renewed, the page asks to sign in again.
- If the connection to Ubisoft's download service does not open within 20 seconds, iDeck stops waiting: the games already listed stay on the page, and the reason goes to iDeck's log.
- The sign-in screen no longer has the "Ubisoft account" button that opened Safari. Signing in happens only inside iDeck.

### Version
- Updated the application version to 2.13.1 (build 119).
