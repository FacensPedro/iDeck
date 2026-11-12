## What's Changed
### Windows runtime
- The 32-bit (WoW64) runtime now has NTMARTA.dll and CLBCATQ.dll, which Wine does not ship. 32-bit programs that load them by name no longer fail with STATUS_DLL_NOT_FOUND (0xC0000135).
  - NTMARTA.dll forwards GetNamedSecurityInfoW, SetNamedSecurityInfoW, GetSecurityInfo, SetSecurityInfo, SetEntriesInAclW, GetExplicitEntriesFromAclW, TreeResetNamedSecurityInfoW and TreeSetNamedSecurityInfoW to Wine's advapi32.
  - CLBCATQ.dll provides the standard COM entry points of an empty COM+ catalog.

### Release
- Updated the application version to 1.8.1 (build 63).
