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

The Steam authentication code in `iDeck/SteamManager.swift` includes adapted source from [Madeira](https://github.com/willfaust/Madeira), including the SwiftSteam sign-in flow. The upstream source headers and copyright notices are retained in the file. Consult [LICENSES/Madeira-COPYING](LICENSES/Madeira-COPYING) and [LICENSES/Madeira-LICENSE-EXCEPTION.md](LICENSES/Madeira-LICENSE-EXCEPTION.md) for the upstream terms. This iDeck fork integrates Steam sign-in, querying the owned-games list, depot downloads and install manifests. The Windows workspace now includes a shared visual library for installed Steam games, imported Windows executables and IPA-installed guest apps, with per-item details, safe uninstall paths and local game profiles. The repository now includes a native build/link pipeline for the upstream FEX, ARM64EC Wine, WineMetal/DXMT and D3D12 bridges, plus bundled Wine-prefix setup. A successful native build and Windows game execution are not yet verified: the default IPA remains interface-only. A macOS native build must complete without errors and pass device tests before claiming Windows game support. See [docs/MADEIRA_RUNTIME_INTEGRATION.md](docs/MADEIRA_RUNTIME_INTEGRATION.md) for the exact missing pieces and required verification.


## Compilar IPA com Madeira (FEX/Wine/DXMT/D3D12)

**Aviso:** o workflow padrão produz `iDeck-interface-only`. Ele permite testar a interface e o Steam, mas **não executa jogos de Windows**. Um IPA pequeno com esse nome não é uma compilação do Madeira.

Para tentar a compilação nativa no GitHub:

1. Abra [GitHub Actions → iOS Build](https://github.com/FacensPedro/iDeck/actions/workflows/ios.yml) e escolha **Run workflow** na branch `main`.
2. Marque **Require real FEX/Wine/DXMT/D3D12 binaries and linked bridge** (`require_madeira=true`).
3. Leia os termos do **Apple Metal Shader Converter**. Marque a confirmação `accept_converter_license` **somente** se tiver autorização para incluí-lo no IPA que será disponibilizado.
4. Execute o workflow. A etapa nativa busca o Madeira fixado, prepara LLVM-MinGW e LLVM iOS, compila e vincula FEX/Wine/DXMT e verifica os módulos PE, símbolos Mach-O e o manifesto do bundle.
5. O upload só terá o nome `iDeck-Madeira-native` se todas as etapas exigidas terminarem com sucesso. Se a compilação falhar por falta de dependências ou incompatibilidade das toolchains, **não existe um IPA nativo utilizável nessa execução**.

A compilação nativa é experimental, exigente em armazenamento/tempo de CPU e ainda não foi validada em dispositivo. Mesmo com todos os arquivos presentes, são necessários assinatura compatível com o iPad, JIT funcional e testes reais de inicialização do Wine, FEX, gráficos e jogos. Consulte [a documentação da vinculação Madeira](docs/MADEIRA_NATIVE_LINKING.md).
