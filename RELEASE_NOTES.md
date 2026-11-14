## What's Changed
### EA app
- EA downloads ask for large files in 8 MB pieces (were 4 MB), half as many requests, so less time goes to waiting for each one. 16 pieces of a file and 20 overall are fetched at once (were 24 and 32); at most 160 MB is held, only while downloading.

### Steam, GOG and Epic Games
- Their piece sizes are fixed by each store's servers, so only how many are fetched at once can change; that stays as in 2.4.3 (48 at once).

### Bugs & logs
- Bug reports list the programs the last Windows session started, oldest first, from Wine's log: what a game installs or runs at its first start (Visual C++, DirectX, PhysX, .NET, its own launcher or installer), each marked as installer or program. Steam's own install scripts for a game are listed too.

### Release
- Updated the application version to 2.4.4 (build 83).
