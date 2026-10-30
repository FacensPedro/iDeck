# Status do runtime Madeira no iDeck

## Revisão de integração nativa — branch `feature/madeira-runtime` (29/10/2026)

**Esta revisão não comprova que um programa Windows funcione em iPhone/iPad.**
A Etapa 0 possui uma execução macOS aprovada, documentada abaixo. As Etapas
1–7 continuam dependentes das provas de compilação, assinatura e dispositivo.

- **SDK LLVM 15 (correção de contrato):** o validador de
  `scripts/llvm_ios_sdk.py` agora exige os arquivos realmente emitidos
  por TableGen (`llvm/IR/IntrinsicEnums.inc` e
  `llvm/IR/IntrinsicImpl.inc`), em lugar do arquivo inexistente
  `llvm/IR/Intrinsics.inc`. Os testes continuam rejeitando cabeçalhos,
  arquivos estáticos e revisões incompletos. A validação do compilador
  iPhoneOS é feita por `scripts/verify_dxmt_llvm.sh`.
- **Verificação independente macOS:** o workflow
  `.github/workflows/madeira-llvm-sdk.yml` prepara as toolchains
  públicas, compila LLVM para iOS, executa os testes e valida os
  cabeçalhos e archives reais. Um resultado de interface **não**
  substitui uma execução aprovada desse workflow.
- **FEX e Wine (fortalecimento das bridges):** quando
  `IDECK_NATIVE_MADEIRA_ENABLED=1`, a disponibilidade passa a
  depender de referências reais a `fex_initialize`,
  `wineserver_start`, `wineserver_is_ready`,
  `wine_process_start` e `wine_process_is_running`.
  A inicialização FEX não usa fallback por `dlsym`; o encerramento
  de Wine usa diretamente `winios_post_key(int,int)`, conforme
  o header upstream. O IPA de interface não anuncia estas APIs.
- **Compilação nativa sem redistribuição:** o workflow
  `.github/workflows/madeira-native-compile.yml` tenta compilar
  as dependências públicas FEX, Wine ARM64EC, DXMT e D3D12 em runner
  macOS, preparar as bridges reais e vincular um executável iOS
  **não assinado** para conferir os símbolos por `nm`.
  Não publica IPA, DLLs, converter proprietário ou kit pré-compilado.
  A aprovação de execução e vinculação deve ser consultada nos
  resultados da própria execução, não inferida da presença do script.
- **Memória:** `iDeck/iDeck.entitlements` solicita agora
  `com.apple.developer.kernel.extended-virtual-addressing` além de
  `increased-memory-limit`. A concessão efetiva das duas permissões
  no app **assinado** não foi verificada; não há declaração de
  autorização de provisionamento. As verificações funcionais do
  pool RX/RW do Wine e do depurador JIT continuam obrigatórias.
- **Licenças e segurança:** `verify_madeira_bundle.py` não foi
  afrouxado; `IDECK_REQUIRE_MADEIRA=1` continua sendo necessário
  para habilitar o runtime no IPA. Não houve redistribuição do Metal
  Shader Converter. Antes de qualquer distribuição, é necessária
  confirmação separada dos direitos de licença e assinatura correta.

### Ordem obrigatória para assinatura e aceitação física

1. Num Mac com Xcode e SDK iPhoneOS compatíveis, compilar os componentes
   nativos fixados, conferir todos os símbolos do executável via `nm` e
   verificar `build/Staging/iDeck.app` usando
   `python3 scripts/verify_madeira_bundle.py --app build/Staging/iDeck.app --require --require-wow64`.
   **O modo estrito modifica o manifesto do bundle:** usá-lo só **antes**
   da assinatura. Uma falha invalida a candidatura à assinatura.
2. Somente após o responsável confirmar os termos do Apple Metal Shader
   Converter, e dispor de certificado e perfis de provisionamento próprios,
   assinar os binários Mach-O e as duas cópias do converter, a extensão
   VPN e finalmente o aplicativo com o mesmo Team ID. Não alterar os
   arquivos após a assinatura.
3. Com o **app já assinado**, executar
   `python3 scripts/verify_signed_madeira_app.py --app /caminho/iDeck.app`.
   Este verificador é somente de leitura: confere assinatura, Team ID,
   provisionamento, validade do perfil, IDs do app e entitlements
   concedidos, sem regravar o manifesto. É propositalmente separado do
   verificador estrito.
4. Instalar o app assinado em um iPhone/iPad físico autorizado, com a
   versão correta do iOS, conferir os entitlements efetivos no runtime,
   ativar um depurador JIT compatível e iniciar um aplicativo Windows
   conhecido e permitido dentro do prefixo Wine. Conferir que o
   wineserver e o guest são threads no mesmo processo, sem `fork`.
5. Registrar evidência real e datada: log da abertura do EXE,
   `wine_process_is_running`, contador de presents com incremento,
   primeira imagem visível na tela Metal, áudio audível, entrada
   funcional, código/status de saída e encerramento das threads.
   É obrigatório não confundir o primeiro frame da interface SwiftUI
   com um frame do guest Windows.
6. Declarar PASS apenas se todos os registros acima forem reais e
   reproduzíveis num aparelho identificado pelo modelo e versão do
   sistema. A ausência de hardware, provisionamento ou direitos de
   redistribuição significa **PENDENTE**, nunca aprovação simulada.

**Situação dos critérios:** nenhum `IDECK_REQUIRE_MADEIRA=1` final foi
aprovado nesta revisão; não há observações verificadas de abertura,
primeiro frame, áudio ou encerramento de um app Windows num dispositivo
real. A etapa de vinculação sem assets não substitui
`verify_madeira_bundle.py --app <app> --require`.

---

## Diagnóstico reprodutível — Etapa 0 (29/10/2026)

**Status: Etapa 0 verificada em macOS/Xcode. Etapa 1 não iniciada nesta
auditoria; insumos de desenvolvimento estão ausentes no clone limpo.**
Esta seção descreve **resultados medidos**, não a compatibilidade
de um aplicativo Windows em iPhone ou iPad.

Execução macOS:
[GitHub Actions #40969996677](https://github.com/FacensPedro/iDeck/actions/runs/40969996677),
artefato
[`ideck-madeira-stage0-diagnostics`](https://github.com/FacensPedro/iDeck/actions/runs/40969996677/artifacts/12939289828).
Fonte reproduzível:
`bash scripts/diagnose_madeira_stage0.sh`, no workflow
`.github/workflows/madeira-stage0.yml`. Os logs contêm o fetch, a
revisão e o status dos submódulos, a lista de pré-requisitos e a saída
integral do verificador.

| Comando/verificação | Resultado observado |
|---|---|
| `bash scripts/fetch_madeira_sources.sh` | **PASSOU**. Madeira em `fd9f2f3d0434a4116e4c3351f286a0fc376b4e36`, incluindo fontes FEX, Wine 11.4, DXMT, bridges e `docs/BUILDING.md`. |
| Xcode/SDK do runner | **DISPONÍVEL**. macOS arm64, Xcode 27.2, `xcodebuild`, `xcrun` e SDK `iphoneos`. |
| Ferramentas do runner | `git`, `cmake`, `ninja`, `clang` disponíveis; **`meson` e `llvm-config` ausentes**. `/usr/bin/bison` existe, mas é GNU Bison **2.3**, incompatível com a configuração Wine 11.4, que exige >= 3.0. |
| Prérequisitos na árvore Madeira | **Ausentes:** `toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/arm64ec-w64-mingw32-clang`, `toolchains/llvm-ios-build/include/llvm/Config/llvm-config.h`, `toolchains/gnutls-ios/include/gnutls/gnutls.h` e `toolchains/ffmpeg-ios/include/libavcodec/avcodec.h`. São dependências geráveis/instaláveis; não há placeholders. |
| Conversor Metal no checkout upstream | `app/Madeira/d3d12/libmetalirconverter.dylib` **estava presente na árvore do Madeira**. É proprietário; sua presença não autoriza cópia para um IPA nem redistribuição. |
| `IDECK_REQUIRE_MADEIRA=0 bash scripts/build_ipa.sh` | **PASSOU**. `iDeck.ipa` de interface criado sem ativar a flag nativa. |
| `python3 scripts/verify_madeira_bundle.py --app build/Build/Products/Release-iphoneos/iDeck.app --require` | **FALHOU como esperado**. Relatou falta de `fex_initialize`, `wineserver_start`, `wine_process_start`, `ideck_madeira_launch_v1`, bibliotecas Windows, Wine prefix, LuaJIT, shaders, certificados e demais assets. O verificador não foi afrouxado. |
| Mesmo verificador sem `--require` | **PASSOU apenas como interface**; nenhum `MadeiraRuntimeManifest.plist` foi criado. |
| Aplicativo Windows e dispositivo real | **NÃO TESTADOS**. Nenhum frame Metal, inicialização de guest ou encerramento Windows foi comprovado neste teste. |

O documento upstream `vendor/Madeira/docs/BUILDING.md` do commit fixado
registra historicamente os forks como não publicados; nesta auditoria,
os commits fixados dos repositórios públicos `willfaust/FEX`,
`willfaust/wine`, `willfaust/dxmt` e `willfaust/rpmalloc` puderam
ser consultados, e o fetch recursivo passou no runner.

**Bloqueio para Etapa 1:** instalar/preparar Meson, GNU Bison >= 3,
LLVM-MinGW ARM64EC fixado com SHA-256, o SDK LLVM iOS com cabeçalhos
completos e as dependências GnuTLS/FFmpeg antes de compilar o runtime.
O script `scripts/prepare_madeira_toolchains.sh` e os builders existentes
são o caminho de preparação, mas a auditoria **não** os executou
nem declara esses artefatos gerados. Também não permite usar
`IDECK_NATIVE_MADEIRA_ENABLED=1` no build padrão.

Um build nativo anterior, em
[GitHub Actions #40960844086](https://github.com/FacensPedro/iDeck/actions/runs/40960844086),
chegou a gerar FEXCore e `xtajit64.dll`, mas falhou depois por
cabeçalhos LLVM ausentes ao compilar componentes do Wine/DXMT. Essa
evidência anterior **não** demonstra que o build nativo completo,
o IPA assinado ou o lançamento em hardware estejam funcionando.
A PR #91 separada propõe corrigir esses includes e a vinculação
estática; ela não foi incorporada como parte desta Etapa 0.

**Distribuição:** nenhum Metal Shader Converter, runtime Wine/FEX/DXMT,
IPA nativo ou DLL proprietária foi publicado pela auditoria. A
revisão das licenças e a autorização explícita continuam obrigatórias.

---

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
