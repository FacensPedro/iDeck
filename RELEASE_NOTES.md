## What's Changed
### Ubisoft Connect
- Nothing is written over Ubisoft game covers any more. A game without a cover shows a plain controller icon, and the title stays under the card.
- The Ubisoft sign-in remembers your email and password: after you sign in, they are kept in this device's Keychain (encrypted, not synced) and filled in next time. Signing out ends the session and deletes them.

- iDeck now finds the version of the installed Ubisoft Connect and sends it to Ubisoft's download service. 2.15.1 looked for it in the wrong part of the version number and sent its old built-in one, which the server refuses. The versions it reads are written to the log.

### Game language
- Every game's page, on Steam, Epic Games, GOG, Ubisoft Connect and the EA app, has a Game language choice. Automatic keeps iDeck's language, as before.
- It lists the languages the game has when the store says so:
  - Steam lists only the game's languages, and marks which have audio, subtitles or both.
  - GOG and Ubisoft list them once the game's file list has been read.
  - Epic and the EA app do not say, so the usual set of languages is offered.
- Steam, GOG and Ubisoft download that language's files. Epic and EA games receive it when they start.
- Stores have one language per game, for both voices and subtitles; the game uses it for whichever it has.

### EA app
- The game licence iDeck gets from EA is now also saved where Origin kept it (C:\ProgramData\Origin\LicenseCache), not only in the EA app's folder. Older EA games' activation, such as Dragon Age: Inquisition's, comes from the Origin era.
- iDeck's log now says, for each licence, whether its machine identity, account and game match what was asked, and when it starts.

### JIT
- With the built-in JIT method, iDeck now enables JIT by itself when it opens, once per opening: no tap is needed. It does this only when the device's pairing file is imported and JIT is not already active.

### Settings
- After JIT is prepared, Settings › JIT shows "Done: JIT ready" in green instead of "Detached" in orange. iDeck lets the debugger go on purpose once Wine's JIT memory is prepared, with StikDebug or the built-in helper, so this was never a lost connection.
- Download notifications now shows as off when iDeck is not allowed to send notifications. After "Don't Allow", or a notification prompt that was dismissed, it used to show as on.

### Version
- Updated the application version to 2.16.0 (build 124).
