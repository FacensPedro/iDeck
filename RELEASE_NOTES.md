## What's Changed
### Ubisoft Connect
- Ubisoft games download again when Ubisoft's download service closes the secure connection right away (the error "server closed session with no notification"). iDeck now tries a second time with the older secure-connection version (TLS 1.2), then a third time over IPv4. Each try is written to iDeck's log.

### Version
- Updated the application version to 2.14.1 (build 122).
