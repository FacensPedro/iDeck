## What's Changed
### EA app
- EA downloads ask for large files in 8 MB pieces (were 4 MB), half as many requests, so less time goes to waiting for each one. 16 pieces of a file and 20 overall are fetched at once (were 24 and 32); at most 160 MB is held, only while downloading.

### Steam, GOG and Epic Games
- Their piece sizes are fixed by each store's servers, so only how many are fetched at once can change; that stays as in 2.4.3 (48 at once).

### Release
- Updated the application version to 2.4.4 (build 83).
