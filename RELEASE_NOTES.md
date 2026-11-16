## What's Changed
### Diagnostics for iPhones without extended virtual addressing
- On a 63 GB address map Wine still stops right after it connects to wineserver (in `server_pipe`, while the first thread sets up its pipes), even with the 2.7.4 limit. The SIGSEGV handler that catches it on iOS belongs to wineserver and only printed "wineserver crashed". It now also logs an `[ideck-fault]` line with the faulting address, PC, LR, SP, ESR and FAR, and catches SIGBUS too, so the next log names the exact memory access that fails.

### Version
- Updated the application version to 2.7.5 (build 95).
