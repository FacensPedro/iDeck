# iDeck

iOS app (SwiftUI) that experiments with running Windows apps on iPhone/iPad: a Wine prefix (from the
[Madeira](https://github.com/willfaust/madeira) template). JIT activation is handled externally by StikDebug; iDeck does not activate JIT itself.

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

## JIT via StikDebug

Activate JIT for iDeck using StikDebug. Return to iDeck Settings and choose **Confirm JIT activated in StikDebug**. This confirmation only updates iDeck’s UI state; it does not activate JIT or independently verify that JIT is enabled. If iDeck is relaunched, repeat the confirmation after activating JIT in StikDebug.

## Branding assets
The mode screens show the mark of the engine behind each mode when an image set with this name exists in
`iDeck/Assets.xcassets`; otherwise an SF Symbol is used:

| Image set name        | Used for                      |
|-----------------------|-------------------------------|
| `MadeiraLogo`         | Windows mode                  |
| `LiveContainerSymbol` | LiveContainer mode            |

Add the official files from those projects yourself (check their brand/licence terms). The app icon is
`iDeck/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (1024x1024, opaque PNG); replace it with your own artwork.


## Third-party components

The Steam authentication code in `iDeck/SteamManager.swift` includes adapted source from [Madeira](https://github.com/willfaust/Madeira), including the SwiftSteam sign-in flow. The upstream source headers and copyright notices are retained in the file. Consult [LICENSES/Madeira-COPYING](LICENSES/Madeira-COPYING) and [LICENSES/Madeira-LICENSE-EXCEPTION.md](LICENSES/Madeira-LICENSE-EXCEPTION.md) for the upstream terms. This iDeck change integrates Steam sign-in and querying the owned-games list. The Steam depot downloader and app-manifest writer have been integrated from Madeira. Owned games can be downloaded into the Wine prefix's Steam library when Steam grants the required depot access. Game execution still depends on a working Madeira FEX/Wine/DXMT runtime, which is not yet integrated in this iDeck fork.
