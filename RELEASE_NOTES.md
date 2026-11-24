## What's Changed
### Ubisoft Connect
- Nothing is written over Ubisoft game covers any more. A game without a cover shows a plain controller icon, and the title stays under the card.
- The Ubisoft sign-in remembers your email and password: after you sign in, they are kept in this device's Keychain (encrypted, not synced) and filled in next time. Signing out ends the session and deletes them.

- iDeck now finds the version of the installed Ubisoft Connect and sends it to Ubisoft's download service. 2.15.1 looked for it in the wrong part of the version number and sent its old built-in one, which the server refuses. The versions it reads are written to the log.

### Settings
- After JIT is prepared, Settings › JIT shows "Done: JIT ready" in green instead of "Detached" in orange. iDeck lets the debugger go on purpose once Wine's JIT memory is prepared, with StikDebug or the built-in helper, so this was never a lost connection.
- Download notifications now shows as off when iDeck is not allowed to send notifications. After "Don't Allow", or a notification prompt that was dismissed, it used to show as on.

### Version
- Updated the application version to 2.15.2 (build 124).
