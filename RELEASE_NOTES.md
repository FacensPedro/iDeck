## What's Changed
- Fixed Dragon Age: Inquisition's ActivationUI.exe failing with 0xC000001D. In 32-bit helper processes, wow64.dll and xtajit.dll (pure ARM64) were linked to the x86-64 entry points of ARM64EC ntdll functions such as RtlRunOnceExecuteOnce. They now link to the native ARM64 code.
- Updated the application version to 1.4.9 (build 36).
