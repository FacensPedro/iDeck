# Integração do runtime Madeira no iDeck

Status em 2026-10-24: o iDeck possui adaptadores nativos, mas NÃO inclui as bibliotecas originais FEX, Wine ARM64EC, DXMT e launcher integrado. O erro de runtime ausente continuará em builds que não tenham esses componentes.

Código-fonte: https://github.com/willfaust/Madeira . O projeto Madeira emprega forks próprios e toolchains específicos. Consulte docs/BUILDING.md e docs/LICENSING.md no repositório upstream.

Compilação necessária no macOS/Xcode:
1. Clone o Madeira com submódulos, confirme que os commits dos forks estão disponíveis e prepare as toolchains LLVM/Mingw documentadas.
2. Compile os componentes FEX para iOS e ARM64EC usando build/fex-ios/build.sh e build/fex-arm64ec/build.sh.
3. Compile Wine ARM64EC, libs Unix e seus módulos PE com os scripts build/ntdll-unix, build/wineserver, build/win32u-unix e build/wine-pe.
4. Compile DXMT, DLLs PE e as dependências D3D12 usando os scripts upstream.
5. Vincule os arquivos estáticos ao projeto Xcode do iDeck, copie a árvore de DLLs Wine para o bundle e desenvolva uma implementação real da ABI ideck_madeira_launch_v1. O código de adaptador do iDeck NÃO implementa esse símbolo.
6. Verifique no executável iDeck os símbolos reais fex_initialize, wineserver_start, wine_process_start, madeira_get_present_count, madeira_d3d12_canary_run e ideck_madeira_launch_v1. Inclua as licenças GPL/LGPL e teste JIT e os jogos no dispositivo.

Importante: não é possível instalar e vincular dinamicamente esse código nativo apenas ao abrir o IPA no iPad. O runtime precisa ser integrado, compilado e assinado como parte do próprio aplicativo. Este documento descreve os requisitos; não afirma que a integração já foi concluída.
