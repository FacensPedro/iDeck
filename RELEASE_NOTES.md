## What's Changed
- The initial setup's Windows runtime step installs only the x64 and x86 Wine environments. The Steam client and Steam's DLLs are installed only from the Madeira Dock step.
- Installing GOG Galaxy from the initial setup failed with "Metal display surface did not become ready. Wine was not started" because the setup screen covered the Windows display. The setup now steps aside while the installer runs and returns when it ends.
- Updated the application version to 1.6.6 (build 47).
