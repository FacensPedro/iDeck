# Status do runtime Madeira no iDeck

## Análise baseada no código upstream

Fonte: https://github.com/willfaust/Madeira, projeto com dependências nativas FEX, Wine ARM64EC, DXMT, Metal e D3D12. O iDeck atualmente tem **pontes e verificações**, mas não contém os binários do emulador nem um launcher operacional no IPA distribuído.

| Componente | Madeira upstream | iDeck atual | O que falta |
|---|---|---|---|
| FEX CPU/JIT | `app/Madeira/FEXBridge.mm`, FEXCore `.a`, `xtajit64.dll` | `NativeRuntime/FEXRuntime.cpp` procura símbolo | Compilar a versão iOS do fork e vincular a implementação real ao executável |
| Wine ARM64EC | `WineServerBridge.m`, `WineProcessBridge.m`, `libwineserver.a`, `libntdll_unix.a`, módulos PE | Bridges ABI via `dlsym` | Compilar e vincular Wine Unix, fazer bundle da árvore DLL e prover template do prefixo |
| DXMT | `libdxmt_combined.a`, `winemetal.dll`, `d3d11.dll`, `dxgi.dll` | Adapter de presença Metal | Compilar backend nativo e os módulos Windows DXMT |
| D3D12 | `d3d12.dll`, `d3d12core.dll`, conversor Metal Shader Converter | Diagnóstico de presença | Incluir DLLs, biblioteca Metal Shader Converter **conforme licença** e dependências |
| Launcher nativo | Configura `MADEIRA_EXE` e `MADEIRA_ARGS` e chama `wine_process_start(prefix)` depois de iniciar o wineserver | Chamadas Wine de ABI incorreta no adaptador antigo | Nesta revisão foram corrigidas as assinaturas e o mapeamento de caminhos. Ainda precisa de símbolos realmente vinculados e testes no iPad |
| Render/entrada | Madeira tem integração específica do frame buffer e janela | Metal UI própria do iDeck | Adaptar callbacks de apresentação/controle, áudio, encerramento e gerenciamento de processo |

### Correção de ABI feita nesta revisão

A API Madeira upstream usa:

- `int wineserver_start(const char *prefix_path)` e `int wineserver_is_ready(void)`.
- `int wine_process_start(const char *prefix_path)` e `int wine_process_is_running(void)`.

No iDeck, `wineserver_start` era chamado incorretamente sem argumento e `wine_process_start` recebia um executável em lugar do **caminho do prefixo**. As novas bridges usam as assinaturas corretas. O launcher converte um arquivo do prefixo `drive_c/` para caminho `C:\\...`, valida o PE e configura `MADEIRA_EXE` / `MADEIRA_ARGS`, como esperado pelo Madeira.

O símbolo público `ideck_madeira_launch_v1` **não** é exportado na compilação básica. Ele só é compilado quando a flag `IDECK_NATIVE_MADEIRA_ENABLED=1` é definida na compilação Objective-C++. Não ative a flag sem as bibliotecas reais. O verificador de empacotamento também exige os símbolos FEX/Wine/DXMT/D3D12 e as DLLs no bundle.

### Compilação de componentes nativos

1. Em macOS/Xcode, executar `bash scripts/fetch_madeira_sources.sh`; o checkout é fixado num commit upstream.
2. Instalar toolchains e dependências listadas em `vendor/Madeira/docs/BUILDING.md`. O upstream observa que **nem todos os insumos são obtidos em um clone limpo** e alguns forks/submódulos históricos podem não estar disponíveis publicamente.
3. Compilar FEX com `bash scripts/build_fex.sh` e `vendor/Madeira/build/fex-arm64ec/build.sh`.
4. Compilar Wine Unix, WineServer, win32u e módulos PE com os scripts `build/ntdll-unix`, `build/wineserver`, `build/win32u-unix` e `build/wine-pe` da árvore Madeira.
5. Compilar DXMT via `bash scripts/build_dxmt.sh`, seu módulo PE, e D3D12 via `bash scripts/build_d3d12.sh`.
6. Integrar os arquivos `.a`, bridges upstream, frameworks/headers, DLLs e assets Wine na target Xcode do iDeck; assinar os binários necessários. Isto **ainda não foi executado**.
7. Gerar um IPA apenas após `python3 scripts/verify_madeira_bundle.py --app <iDeck.app> --require` e verificar no iPad real que uma aplicação Windows abre, renderiza e encerra.

A integração do pipeline de compilação Xcode das bibliotecas upstream **continua pendente** e não pode ser substituída por renomear arquivos, editar mensagens de erro ou modificar um IPA sem assinatura.

### Importação IPA / LiveContainer

O reparo do extrator aceita registros legítimos de diretório (`Payload/GetMoreRam.app/`) e adia a criação dessas pastas até haver arquivos para gravar. Mantém checagem de traversal e links simbólicos. **Importar um IPA não significa executá-lo no LiveContainer**. Executar aplicativos dentro de outro aplicativo depende de um runtime compatível e das restrições de assinatura do iPadOS.

### Empacotamento opcional do runtime

O script `scripts/build_ipa.sh` permanece compatível com IPA de interface sem as bibliotecas Madeira. Ao usar `IDECK_REQUIRE_MADEIRA=1`, ele ativa a ABI de lançamento **somente nesse build**, executa `scripts/stage_madeira_payload.sh` para copiar as DLLs compiladas do Wine/DXMT/FEX para `iDeck.app/MadeiraRuntime` e então executa o verificador em modo obrigatório. Se faltar alguma biblioteca, símbolo nativo ou arquivo do bundle, o build termina em erro — não é produzido um IPA anunciado como funcional.

A biblioteca proprietária Metal Shader Converter só será incluída com `IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1`, após o responsável confirmar que possui autorização para redistribuí-la, e ainda deverá ser assinada adequadamente. Esta etapa **não** compila nem vincula as bibliotecas estáticas upstream, nem os arquivos-fonte de integração originais. Enquanto isso não for feito, o modo obrigatório deve falhar, como esperado.

O GitHub Actions reutiliza agora o mesmo `scripts/build_ipa.sh` para evitar que builds locais e CI empacotem conteúdos diferentes. A infraestrutura macOS/Xcode e o status de billing da conta continuam requisitos externos.
