## What's Changed
### iPhones without extended virtual addressing
- Fixed the crash right after Wine started on a 63 GB address map (iPhone 15 signed without extended virtual addressing). Wine believed the map ended at 64 GB, placed the first thread's TEB in the last 128 KB below the real 0xfc0000000 ceiling, and crashed in `server_pipe` while setting up the thread. Wine now keeps 1 GB below the kernel's real ceiling on such maps.

### Version
- Updated the application version to 2.7.4 (build 94).
