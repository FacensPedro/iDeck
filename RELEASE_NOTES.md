## What's Changed
### Games
- Fixed Fallout: New Vegas from Epic Games closing when Play is tapped in its launcher. After the game's message hook ran, the address of its result was lost, the write faulted and the error handling ran until the stack ran out. The address is now kept safely across the call, as was already done for window messages.

### Game language
- The language chosen on a game's page is now Windows' own language for that game: games that pick their dubbing and subtitles from the system language (most of them) follow it. Before, Windows always had the device's language.
- Steam games: the choice is written to the game's install record at once, so subtitles the game already has switch at the next start; dubbing in another language is downloaded by the update the page starts.

### Version
- Updated the application version to 2.16.4 (build 128).
