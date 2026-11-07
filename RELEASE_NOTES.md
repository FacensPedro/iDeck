## What's Changed
- Added GOG Galaxy services for GOG games: while a GOG game runs, iDeck answers its Galaxy SDK on 127.0.0.1:9977 (sign-in, achievements, stats, leaderboards and play time) with a token GOG mints for that game's own client.
- Registered the GalaxyCommunication service in the Wine prefix for Galaxy SDK versions that start it first.
- Steam's DirectX June 2010 setup is no longer run: Wine's built-in DirectX DLLs are used. Running it stopped iDeck before Cuphead could start.
- A saved 896 MB JIT pool (the old default, which never fits on these devices) moves to 624 MB once.
- Updated the application version to 1.4.2 (build 29).
