## What's Changed
Faster, quieter game starts.
- The Wine prefix's ~1,450 DLL links are now only rewritten when they changed (after a reinstall or a switch between 32-bit and 64-bit games), not on every launch.
- FEX no longer searches dozens of nonexistent folders for its configuration in every process.
- Wine Mono remembers that fusion.dll is not installed instead of trying to load it again for every .NET assembly.
- Updated the application version to 1.5.1 (build 40).
