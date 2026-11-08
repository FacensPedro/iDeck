## What's Changed
- Fixed a crash in Crash Bandicoot N. Sane Trilogy about 40 seconds after launch. When the JIT fixed an unaligned atomic load or store, it could overwrite a neighbouring instruction, which cut a pointer to 32 bits. It now emulates that access without changing the code.
- Bug reports no longer say an x18 failure ended in 0xC000001D when the real status was an access violation (0xC0000005).
- Updated the application version to 1.4.8 (build 35).
