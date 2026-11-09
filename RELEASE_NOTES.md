## What's Changed
- The initial setup's Windows runtime step installs only the x64 and x86 Wine environments. The Steam client and Steam's DLLs are installed only from the Madeira Dock step.
- GOG works like Madeira: iDeck no longer installs the GOG Galaxy client, and the initial setup's GOG Galaxy step is gone. iDeck does what Galaxy does around a game:
  - Before each start, the game's install script registry values are written. Some launchers quit without them, such as The Witcher: Enhanced Edition's.
  - The build's redistributables (openAL, older Visual C++ and others) are downloaded with the game, and their installers run once before its first start.
  - Galaxy game services (sign-in, achievements, stats) keep working through iDeck.
- Updated the application version to 1.6.6 (build 47).
