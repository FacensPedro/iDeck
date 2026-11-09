## What's Changed
- Fixed Windows programs not starting since the runtime moved out of the IPA: Wine still looked for its NLS files (locale.nls, l_intl.nls, normnfc.nls) inside the app, and the wineserver crashed. The 1.6.4 fix patched Wine's generic loader, but iOS builds compile Madeira's own loader_ios.c. That file now reads them from the downloaded runtime, and the native runtime cache key covers the patch scripts so it is rebuilt.
- Fixed GOG installs failing with HTTP 404 on redistributables (`__redist/...`): their chunk addresses were missing the chunk path. Redistributables also no longer fail a game's install when one of them cannot be downloaded.
- Updated the application version to 1.6.7 (build 48).
