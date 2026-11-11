## What's Changed
### Windows runtime
- The runtime now carries all of Wine's code page tables (76 NLS files instead of 12). Windows takes its language from the device, so an iPad or iPhone set to Portuguese, Spanish, French, German, Japanese, Russian or any language other than English asked for tables that were missing; `cmd.exe`, console programs, installers and games that convert text failed on them.
- The build stops if a DLL of the wrong architecture is in a runtime folder (x86 in the x64/ARM64EC folder, x64 in the x86 folder, and so on).
- Madeira's own test programs (22 files) are no longer part of the downloaded runtime or linked into each prefix.

### GOG
- Visual C++ 2005 to 2013 redistributable installers that come with a GOG game are no longer run before the game starts. iDeck installs those runtimes itself, and the installers stopped inside Windows Installer without installing anything. Games installed earlier skip them too.

### Release
- Updated the application version to 1.7.2 (build 54).
