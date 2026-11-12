## What's Changed
### EA app downloads
- A download no longer stops for a while and then goes on. Up to 128 range requests (8 files of 16 ranges) were handed to the system for 40 connections; the ones left waiting timed out after 60 seconds and were fetched again. At most 24 range requests are now in flight, the rest wait inside iDeck with no timeout running, and a connection that stops sending is given up after 30 seconds instead of 60.
- Memory used by ranges in flight drops from up to about 512 MB to about 96 MB.
- A slow file no longer holds back the delivery of every other transfer for up to 30 seconds (now 5 at most).

### Release
- Updated the application version to 1.7.7 (build 59).
