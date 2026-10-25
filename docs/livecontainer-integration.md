# LiveContainer integration status

Reference reviewed: https://github.com/LiveContainer/LiveContainer and its LCContainer model. The management additions below are independent iDeck implementations, not a complete port of the upstream runtime.

Implemented:
- Multiple named data directories per app identifier, with persistent selection, rename and explicit deletion confirmation.
- Documents, Library/Preferences, Library/Caches and tmp directories per container. These are storage directories, not an OS security sandbox or isolated keychain.
- App updates matched by CFBundleIdentifier even if the incoming bundle directory was renamed.
- Serial IPA imports, staged replacement and restoration of the old bundle when the final move fails.
- Single app bundle, executable path and minimum OS checks before replacement.
- Data containers preserved when updating or uninstalling an app; reinstalling the same bundle identifier restores access to their management UI.

Not integrated:
- The upstream guest loader and executable-path/main-bundle hooks as a complete launch chain.
- Certificate/provisioning import, ZSign signing and embedded library/tweak signing.
- Binding the selected data directory to a running guest, preferences, app groups and keychain separation.
- Multitasking extensions, separate guest processes, native windows and PiP.
- TweakLoader, guest URL/file routing and notification/file-picker fixes.

The app still reports that guest execution is unavailable. Merely importing a signed IPA or detecting JIT does not make that launch chain functional. The data-container UI explicitly reports this limitation.

Verification: existing Python bundle tests pass locally; Swift persistence, cross-app deletion rejection and corrupted-manifest tests are configured in GitHub Actions. CoreGraphics is explicitly imported in the rendering model and its host test to address the uploaded CGSize.zero compiler error. Device execution has not been validated.
