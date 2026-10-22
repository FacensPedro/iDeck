# iDeck

iOS app (SwiftUI) that experiments with running Windows apps on iPhone/iPad: a Wine prefix (from the
[Madeira](https://github.com/willfaust/madeira) template), JIT activation through a small helper server and
a LocalDevVPN packet-tunnel extension.

## Build the IPA

### GitHub Actions
Every push to `main` runs the **iOS Build** workflow and uploads `iDeck.ipa` as an artifact. Pushing a tag
such as `v1.0.0` also creates a GitHub release with the IPA attached. The workflow can be started manually too.

### Locally (macOS + Xcode)
```bash
scripts/build_ipa.sh
```
The IPA is **unsigned**; sign and install it with a sideloading tool (AltStore, Sideloadly, ...). The Network
Extension (`VPNExtension`) needs a provisioning profile with the *Network Extensions* capability, and the bundle
identifiers (`com.example.iDeck`, `com.example.iDeck.VPNExtension`) and app group (`group.com.example.iDeck`)
should be changed to your own.

## JIT helper server
```bash
cd server_jit
./setup.sh            # installs pymobiledevice3 and starts server.py on 127.0.0.1:54321
```
Environment variables: `JIT_SERVER_HOST`, `JIT_SERVER_PORT`, `JIT_SERVER_TOKEN` (required when the host is not
loopback). `jit_server.js` is an equivalent Node implementation. The app reads `jitServerURL` and `jitServerToken`
from `UserDefaults`.

## Branding assets
The mode screens show the mark of the engine behind each mode when an image set with this name exists in
`iDeck/Assets.xcassets`; otherwise an SF Symbol is used:

| Image set name        | Used for                      |
|-----------------------|-------------------------------|
| `MadeiraLogo`         | Windows mode                  |
| `LiveContainerSymbol` | LiveContainer mode            |

Add the official files from those projects yourself (check their brand/licence terms). The app icon is
`iDeck/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (1024x1024, opaque PNG); replace it with your own artwork.
