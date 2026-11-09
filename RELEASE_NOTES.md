## What's Changed
- Fixed Windows programs not starting after the runtime moved out of the IPA: Wine's ntdll still looked for its NLS data files (locale.nls, l_intl.nls, normnfc.nls) inside the app bundle, failed to load them and the wineserver crashed. ntdll now reads them from the downloaded runtime.
- Updated the application version to 1.6.4 (build 45).
