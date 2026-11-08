## What's Changed
Stability release for 32-bit games, the JIT pool and native/emulated code transitions.
- OpenGL in 32-bit programs: every memory address a 32-bit program hands to OpenGL now points to the right place on iOS (about 1,800 conversions fixed), the same class of bug that crashed Borderlands 2's launcher.
- 32-bit helper processes: functions looked up at runtime (GetProcAddress) or loaded on first use (delay-load) now link to native ARM64 code, as functions linked at startup already did.
- JIT memory: when a DLL is unloaded, the code memory registered over its pages is released with it, so the next DLL at that address does not inherit stale entries.
- Starting another game: iDeck now waits up to 5 seconds for the previous session to finish closing instead of refusing the launch.
- The session watchdog no longer touches a thread that has already exited.
- The JIT pool now defaults to 560 MB, the largest size that fits on these devices (624 MB was always reduced to 560 MB). Saved 624 MB settings move to 560 MB once.
- iDeck now warns when iOS counts the JIT pool against the app's memory limit, which can make heavy games close without an error.
- Updated the application version to 1.5.0 (build 39).
