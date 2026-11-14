## What's Changed
### Library
- Removed the separator between the stores and the games on the home shelf.

### Game session
- The X button during a game now closes iDeck together with the game. The game gets its close request first and a moment to save; iDeck is opened again for the next game. A session that had ended left memory behind that kept the next game from getting its JIT memory.

### Downloads
- When the last download of a queue ends, iDeck clears its network cache and returns the memory the download used to iOS, so it no longer counts against a game started afterwards.

### Windows runtime
- Added stand-ins for four Direct3D companion DLLs Wine does not implement (d3d11on12, d3d9on12, d3dcsx_42, d3dcsx_43), for 32-bit and 64-bit programs. They answer "not available", so a program that needs the file just to start now starts and uses its ordinary Direct3D path. dxtrans.dll joins the 64-bit set.

### JIT
- Bug reports now show how long the trip to StikDebug and back took: when iDeck was in front again and when the debugger was attached.

### Release
- Updated the application version to 2.3.6 (build 78).
