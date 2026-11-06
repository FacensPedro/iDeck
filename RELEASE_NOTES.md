## What's Changed
- Reduced temporary memory used while verifying previously downloaded Steam files by limiting simultaneous integrity-check readers.
- Improved diagnostics for critical memory-pressure events, including app activity and active Steam installations.
- Recorded the Steam game name and launcher when an installation starts, including before the game is launched.
- Added an interrupted-install diagnostic on the next application launch when the previous installation did not close normally.
- Prevented harmless zero-count Steam status fields from being reported as errors.
