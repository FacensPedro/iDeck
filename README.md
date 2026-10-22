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
JIT is enabled by a helper that runs on a computer connected to the device (USB or Wi-Fi sync, already paired):
```bash
cd server_jit
./setup.sh            # installs pymobiledevice3 and starts server.py on 127.0.0.1:54321
```
It starts `pymobiledevice3 developer debugserver start-server`, attaches to the app's PID over the GDB remote
protocol (`vAttach`) and detaches again, which leaves the process debugged and therefore JIT-capable.
Environment variables: `JIT_SERVER_HOST`, `JIT_SERVER_PORT`, `JIT_SERVER_TOKEN` (required when the host is not
loopback), `JIT_SERVER_UDID`, `JIT_SERVER_TUNNEL` (iOS 17+, a running tunneld).
In the app: Settings -> JIT & Debugging -> enter the server address (and token), then **Activate JIT**.

The imported pairing file is stored on the device only (it contains a private key and is never sent to the
server); an on-device StikDebug-style flow that consumes it is not implemented yet.

## Branding assets
The mode screens show the mark of the engine behind each mode when an image set with this name exists in
`iDeck/Assets.xcassets`; otherwise an SF Symbol is used:

| Image set name        | Used for                      |
|-----------------------|-------------------------------|
| `MadeiraLogo`         | Windows mode                  |
| `LiveContainerSymbol` | LiveContainer mode            |

Add the official files from those projects yourself (check their brand/licence terms). The app icon is
`iDeck/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (1024x1024, opaque PNG); replace it with your own artwork.
