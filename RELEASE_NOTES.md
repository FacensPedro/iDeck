## What's Changed
### Library
- Removed the separator between the stores and the games on the home shelf.

### Game session
- The X button during a game now closes iDeck together with the game. The game gets its close request first and a moment to save; iDeck is opened again for the next game. A session that had ended left memory behind that kept the next game from getting its JIT memory.

### JIT
- Bug reports now show how long the trip to StikDebug and back took: when iDeck was in front again and when the debugger was attached.

### Release
- Updated the application version to 2.3.6 (build 78).
