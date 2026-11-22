## What's Changed
### Library
- The cover of a game that is not installed shows only the install symbol, a round button in the middle of the cover, with no text.
- A game that needs Easy Anti-Cheat shows only the struck-through install symbol in the middle of its cover, with no "Cannot install" text.

### JIT
- Each FEX code buffer taken from the JIT pool no longer tries to protect its last page, name itself or ask for huge pages: iOS refuses all three, so every buffer cost two extra calls into Wine's pool and logged "Failed to mprotect last page of code buffer".

### Version
- Updated the application version to 2.11.1 (build 116).
