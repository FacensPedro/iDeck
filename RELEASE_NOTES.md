## What's Changed
### EA app
- Faster EA game downloads. Since 2.2.1 iDeck asked EA's servers for large files in 2 MB pieces, twice as many requests as before, and each request's wait slowed the download. It is back to 4 MB pieces.
- EA downloads also fetch more at once: 10 files and 24 pieces of a large file in parallel (were 8 and 16), over up to 56 connections. At most 128 MB is held for this, and only while downloading.

### Bugs & logs
- Every download (Steam, GOG, Epic Games, EA app) writes its speed to iDeck's log every 15 seconds, and a line when it finishes, stops or fails, with the reason and the average speed. Bug reports include these lines.

### Release
- Updated the application version to 2.4.2 (build 81).
