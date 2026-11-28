## What's Changed
### Build
- Fixed the IPA build of iDeck 3.1: the Madeira patch that resumes a guarded system call after a fault (madeira-unix-try-mach-fault) passed a pointer where the iOS SDK's thread-state macro takes the state itself, and Madeira's ntdll did not compile.
- The EA app and Epic Games sign-ins wait for Safari to open when Safari's sign-in sheet cannot be shown (a Swift build error in 3.1).

### Display
- No more bars at the sides of the game, in every game: the picture spans the screen's whole width. A picture shorter than the screen leaves its spare space only at the top, and one taller than the screen fits its height. Touch follows the same picture. Fill and Stretch keep working as before.

### Version
- Updated the application version to 3.1 (build 131).
