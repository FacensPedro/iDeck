## What's Changed
### Downloads
- More parallel downloading in every store:
  - Steam: 64 chunks at once (was 48) over up to 96 connections (was 64).
  - Epic Games: 64 chunks in flight (was 48) over up to 96 connections (was 64).
  - GOG: 8 files with 8 chunks each (was 6 chunks) over up to 96 connections (was 64).
  - EA app: 12 files and 32 pieces of a large file at once (were 10 and 24), 40 pieces in flight, over up to 72 connections (was 56).
- The extra memory is used only while downloading and is returned when the queue ends.

### Release
- Updated the application version to 2.4.4 (build 83).
