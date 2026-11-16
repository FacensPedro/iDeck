## What's Changed
### Steam: uninstall and leftover downloads
- A Steam download that failed (for example when the device ran out of space) or was stopped left its files behind, and the game page offered only Install, so the space could not be freed. The page now shows **Delete downloaded files** whenever such files exist, and removes the game folder, the download journal and the manifest.
- The Uninstall button no longer does nothing when the Windows environment is not ready yet: it says so.

### Diagnostics
- The `[ideck-fault]` crash line from 2.7.5 stays.

### Version
- Updated the application version to 2.7.6 (build 96).
