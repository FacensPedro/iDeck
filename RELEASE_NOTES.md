## What's Changed
### iDeck 3
- The first iDeck 3 release. It starts the new architecture: a central session lifecycle (preparing, launching, running, closing, failed, recovering) that every launcher reports to; its last transitions are in the bug report. The full plan is in docs/ARCHITECTURE-3.0.md.
- iDeck System Libraries: a catalog of the public iOS frameworks iDeck uses or may use, with a coverage report (docs/ios-system-libraries.md) that GitHub updates are checked against.
- The IPA is named after the short version: iDeck-3.ipa.
- The five largest files are split by layer: SystemCoordinator into Application/ (diagnostics, JIT, store clients, launch, Madeira Dock, session end), MainView into Presentation/ (library artwork, game pages per store, profile form, first-run setup, home shelves), WindowsEnvironment into Runtime/ (runtime, graphics, game profile, bundle identity, compatibility switches), EALibrary into Stores/EA/ (account, downloads, launch, licence check) and the Ubisoft downloader into Stores/Ubisoft/ (content service, manifest, installer). The Auto DLL Manager is split into catalog, cache and installer (Runtime/AutoDLL/), and the resource governor into memory and background parts (Runtime/Resources/). Screens and the objects behind them are in separate files: the bug report, Epic Cloud saves, external drives and GOG (sign-in and library). Settings is split by page (stores, system, general), with the shared rows and the Ubisoft account in their own files. Behaviour is unchanged.

### Games
- Fixed Fallout: New Vegas from Epic Games closing when Play is tapped in its launcher. After the game's message hook ran, the address of its result was lost, the write faulted and the error handling ran until the stack ran out. The address is now kept safely across the call, as was already done for window messages.

### Game language
- The language chosen on a game's page is now Windows' own language for that game: games that pick their dubbing and subtitles from the system language (most of them) follow it. Before, Windows always had the device's language.
- Steam games: the choice is written to the game's install record at once, so subtitles the game already has switch at the next start; dubbing in another language is downloaded by the update the page starts.

### Build
- The build workflow reads the version from the project only; the stale version in its description is gone.

### Version
- Updated the application version to 3.0 (build 129).
