## What's Changed
### Build
- Fixed the IPA build of iDeck 3.1: the Madeira patch that resumes a guarded system call after a fault (madeira-unix-try-mach-fault) passed a pointer where the iOS SDK's thread-state macro takes the state itself, and Madeira's ntdll did not compile.
- The EA app and Epic Games sign-ins wait for Safari to open when Safari's sign-in sheet cannot be shown (a Swift build error in 3.1).

### Version
- iDeck 3.1 (build 131).
