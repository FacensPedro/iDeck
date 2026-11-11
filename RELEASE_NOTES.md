## What's Changed
### Memory+
- Settings › Windows runtime shows what this installed copy of iDeck really has: Increased Memory Limit (read from the profile the app was signed with), Extended Virtual Addressing (measured), the memory iOS still allows and the App ID.
- When a capability is missing, the page lists GetMoreRam's steps to add Increased Memory Limit to the App ID from the device, with a button to copy the App ID and a link to GetMoreRam.

### Initial setup
- The JIT step only chooses the method, StikDebug or Built-in (with its pairing file). The Enable JIT button is gone: iDeck turns JIT on with the chosen method when a game starts.

### Windows runtime
- Starting a Windows child process no longer leaves the app's environment pointing at freed memory. Wine frees a child's WINEDEBUG string after handing it to the environment, which is safe after a fork but not on iOS, where the child is a thread of iDeck.

### Release
- Updated the application version to 1.7.3 (build 55).
