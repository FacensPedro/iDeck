## What's Changed
- Dragon Age: Inquisition's ActivationUI.exe still failed with 0xC000001D in 1.6.0: the 32-bit side's xtajit.dll called the x86-64 version of ntdll's __chkstk (a single "return" instruction) as if it were ARM code. Exports like that now link to the native ARM64 equivalent.
- Updated the application version to 1.6.1 (build 42).
