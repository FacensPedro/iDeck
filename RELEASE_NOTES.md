## What's Changed
- Dragon Age: Inquisition's ActivationUI.exe still closed at startup in 1.6.1: a loader diagnostic read the 32-bit program's import table as if it were 64-bit, followed a garbage pointer and crashed (access violation, then a stack overflow while unwinding). The diagnostic now skips 32-bit images.
- Updated the application version to 1.6.2 (build 43).
