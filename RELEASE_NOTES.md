## What's Changed
### EA app
- Faster EA game downloads. Since 2.2.1 iDeck asked EA's servers for large files in 2 MB pieces, twice as many requests as before, and each request's wait slowed the download. It is back to 4 MB pieces.
- EA downloads also fetch more at once: 10 files and 24 pieces of a large file in parallel (were 8 and 16), over up to 56 connections. At most 128 MB is held for this, and only while downloading.

### Steam, GOG and Epic Games
- Faster downloads: Steam fetches 48 chunks at once (was 16) over up to 64 connections; Epic Games keeps 48 chunks in flight (was 32) over up to 64 connections (was 48); GOG keeps 48 chunks in flight, 8 files with 6 chunks each (were 4 and 3), over 64 connections (was 12).

### Bugs & logs
- Every download (Steam, GOG, Epic Games, EA app) writes its speed to iDeck's log every 15 seconds, and a line when it finishes, stops or fails, with the reason and the average speed. Bug reports include these lines.

### Release
- Updated the application version to 2.4.2 (build 81).
