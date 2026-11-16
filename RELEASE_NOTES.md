## What's Changed
### Memory+
- Games no longer stop with "iOS did not give iDeck the extended memory address space" when the signing profile lacks extended virtual addressing (iPhones signed with a free Apple ID). As in Madeira, only the increased memory limit is required: on the standard 63 GB address map the JIT pool's memory is placed lower and the pool is kept smaller.

### JIT
- The log now says "opening StikDebug" before StikDebug is asked to open, instead of "StikDebug opened".

### Version
- Updated the application version to 2.7.3 (build 93).
