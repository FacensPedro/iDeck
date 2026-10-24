# Compilação nativa Madeira → iDeck

Este repositório prepara um pipeline **real** para compilar e vincular os componentes iOS do Madeira. Isso não significa que uma build validada já tenha sido produzida. A compilação nativa depende de macOS/Xcode, LLVM para iOS, LLVM-MinGW, forks do Wine/FEX/DXMT e licenças de terceiros.

## Fontes exatas

Madeira: [willfaust/Madeira](https://github.com/willfaust/Madeira), commit `fd9f2f3d0434a4116e4c3351f286a0fc376b4e36` (24 de outubro de 2026). Os gitlinks dos forks foram verificados como publicamente acessíveis nesta revisão:

- FEX `f59cab95659e8add0c88f0c76ec1cf483c536dbf`
- Wine `9129e9684daaeae70da9435e7c6060e59392634e`
- DXMT `128b297c6e9a00014408dc68b4c2c2373b5813de`

Atualizações do upstream podem exigir adequações nas APIs. O checkout é fixado e pode ser substituído explicitamente com a variável `IDECK_MADEIRA_REV`.

## Preparação no Mac

1. Instale Xcode com iPhoneOS SDK, CMake, Ninja, Meson, Python 3 e dependências documentadas por `vendor/Madeira/docs/BUILDING.md`. Prepare especificamente `toolchains/llvm-mingw-20260421-ucrt-macos-universal` e `toolchains/llvm-ios-build`. O LLVM cross-build é um passo não trivial e não é gerado automaticamente pelo iDeck.
2. Execute `bash scripts/fetch_madeira_sources.sh`.
3. Configure e compile previamente os insumos opcionais/necessários para Wine que não estejam no checkout: GnuTLS/GMP/Nettle, FFmpeg e Wine `build-macos`. Os scripts do upstream podem exigir outras toolchains e não foram comprovados num checkout limpo.
4. Leia o acordo de redistribuição do Apple Metal Shader Converter e só ative `IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1` se tiver a autorização necessária.
5. Compile com:

```bash
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 IDECK_REQUIRE_MADEIRA=1 bash scripts/build_ipa.sh
```

Isso executa `scripts/build_madeira_components.sh`, que compila FEX iOS e ARM64EC, Wine ntdll/wineserver/win32u para iOS, DXMT + LLVM, frontends Windows PE do DXMT e D3D12. Em seguida `scripts/link_madeira_native.sh` compila e arquiva as fontes de bridge originais do Madeira para iOS ARM64 e fornece ao Xcode **parâmetros reais de vinculação**, incluindo as bibliotecas nativas e os frameworks Metal, MetalFX, QuartzCore, AVFoundation, GameController e CoreHaptics. O pipeline copia os diretórios Wine e o prefixo para `iDeck.app` nos caminhos esperados pelo upstream.

Os componentes adicionais de Wine e DXMT não são gerados por nomes falsos. Cada arquivo obrigatório ausente cancela a compilação. A montagem do bundle só ocorre depois da vinculação. `verify_madeira_bundle.py --require` verifica símbolos nativos e arquivos Windows PE necessários antes de criar o arquivo `iDeck.ipa`.

Caso todas as bibliotecas já estejam compiladas e autenticadas, a opção `IDECK_MADEIRA_REBUILD=0` pula a recompilação upstream, **não** as verificações de arquivos, a recompilação das bridges, o link ou a verificação do aplicativo.

## Problemas ainda não resolvidos automaticamente

- Necessidade de um Mac para executar `xcrun`, `xcodebuild` e o SDK do iOS. Este ambiente não fornece esses binários. Não é possível afirmar que bibliotecas foram compiladas sem executar o pipeline.
- O upstream ainda documenta pré-requisitos não fornecidos pelo clone, como LLVM cross-build, Microsoft VC++ redistributables (licenciados separadamente) e Metal Shader Converter. Não serão inventados substitutos.
- Fontes Wine/DXMT e linker poderão gerar erros de API/ABI específicos do commit atual. A correção definitiva desses erros requer o log de uma execução Mac.
- O `WindowsRendererView` expõe seu `CAMetalLayer` ao `madeira_display_set_layer` do upstream. A renderização, a entrada e o gerenciamento da sessão ainda exigem testes práticos com jogos.
- A assinatura do IPA (inclusive a dylib do converter Metal) precisa usar identidade compatível com o método de instalação. Um IPA não assinado não substitui isso.
- A integração total com Steam, compatibilidade de jogos e desempenho ainda não foram verificados em hardware real.

A compilação padrão (sem `IDECK_REQUIRE_MADEIRA`) continua criando um IPA de interface, **sem** declarar suporte ao emulador. Nunca o rotule como runtime Madeira integrado.
