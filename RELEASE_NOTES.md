## What's Changed
- Dragon Age: Inquisition's ActivationUI.exe got further after 1.4.9 but still failed with 0xC000001D. wow64.dll and xtajit.dll were still linked to the x86-64 stubs of ntdll's Nt* system calls (NtWaitForDebugEvent and others). They now link to the native ARM64 entry points.
- Updated the application version to 1.4.10 (build 37).
