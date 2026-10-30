# Status do runtime Madeira no iDeck

## Fases 2–11 — gates nativos e dispositivo (30/10/2026)

**A implementação de um gate não prova que ele passou.** A fonte da verdade
sobre o build é o resultado da execução GitHub Actions na revisão exata; a fonte
da verdade sobre o iPad é o procedimento de
[aceitação em dispositivo](MADEIRA_DEVICE_ACCEPTANCE.md).

### Fase 2: LLVM e dependências iPhoneOS reproduzíveis

- Workflow: `.github/workflows/madeira-stage2-toolchains.yml`, que usa
  somente componentes públicos; **não** distribui Apple Metal Shader Converter.
- `bash scripts/prepare_madeira_toolchains.sh` gera ou recupera LLVM 15 e
  llvm-mingw ARM64EC fixado. O script `verify_madeira_toolchains.sh` verifica
  o COFF ARM64EC compilado na hora (`IMAGE_FILE_MACHINE_ARM64EC=0xA641`),
  arquivos `libLLVM*.a` reais para arm64 e headers de LLVM.
- `bash scripts/prepare_madeira_dependencies.sh vendor/Madeira` recompila
  conforme necessário GnuTLS, GMP, Nettle, FFmpeg e FreeType. Após isso,
  `bash scripts/verify_madeira_toolchains.sh --require-deps` verifica
  a existência, arquitetura arm64 e headers dos componentes.
- Os caches de toolchain mantêm chaves versionadas. Um cache inválido
  **falha ou é reconstruído**, nunca pode ser tratado como sucesso apenas
  porque `actions/cache` encontrou arquivos. Dependências demasiado
  grandes não são enviadas ao cache.
- A fase 2 só é aprovada com o job completo em runner macOS/Xcode;
  testes host e uma execução LLVM anterior **não** substituem esse gate.

### Fase 3: compilação FEX isolada em iPhoneOS

O workflow `.github/workflows/madeira-fex-stage3.yml` realiza um build
**somente FEX** a partir da revisão Madeira já fixada, com LLVM/iPhoneOS e
llvm-mingw ARM64EC públicos e verificados. Execute manualmente pelo
`workflow_dispatch` após a integração da PR, ou consulte o run disparado
pela branch de desenvolvimento. Ele publica as três bibliotecas estáticas
FEXCore/Jemalloc e o executável PE `xtajit64.dll` como artefatos de build,
**sem** publicar um IPA de interface como se fosse um emulador.

O script `build_madeira_components.sh` recebe
`IDECK_MADEIRA_STOP_AFTER=fex IDECK_MADEIRA_GRAPHICS=d3d11
IDECK_BUILD_WOW64=0`, dispensando dependências que só serão necessárias
à etapa do Wine (Bison, GnuTLS, FFmpeg, FreeType). A checagem final
`verify_madeira_fex_stage3.py` exige as bibliotecas Mach-O arm64
compiladas, o PE ARM64EC válido e a configuração de montagem
`-DFEX_IOS_HOST=1`, inclusive no assembler do módulo Windows.
Ela grava um recibo com hashes SHA-256 de cada artefato, deixando explícito
que **não** executou instruções Windows nem validou a memória JIT em iPad.

O status de aprovação desta fase deve ser derivado do job macOS
`Compile real FEXCore arm64 and xtajit64 ARM64EC` na revisão exata.
Os testes host confirmam os *gates*, não substituem esse job.

### Fase 4: Wine ARM64EC, Unix libraries e wineserver

A fase 3 passou no job de compilação real
[GitHub Actions #40999473834](https://github.com/FacensPedro/iDeck/actions/runs/40999473834):
FEXCore arm64, allocator iOS e xtajit64.dll ARM64EC, com auditoria
do CMake e recibo de hashes SHA-256.

Na **fase 4**, `.github/workflows/madeira-wine-stage4.yml` invoca
`IDECK_MADEIRA_STOP_AFTER=wine IDECK_MADEIRA_GRAPHICS=d3d11
IDECK_BUILD_WOW64=0 bash scripts/build_madeira_components.sh`.
Isso recompila o FEX e executa o Wine a partir do commit público
pinned 11.4, com LLVM ARM64EC e as bibliotecas iPhoneOS da fase 2,
sem acionar shaders Metal/DXMT ou empacotar um IPA.

O `scripts/verify_madeira_wine_stage4.py` exige `ntdll.dll`
ARM64EC, arquivos estáticos `libntdll_unix.a`,
`libwineserver.a` e `libwin32u_unix.a` para iPhoneOS arm64, além de
confirmar o build/configuração ARM64EC, os cabeçalhos Wine gerados para
ambos os builds, a receita de wineserver compilado das fontes
e os artefatos FEX já exigidos na fase 3. O arquivo
`wine-stage4-receipt.json` relaciona os artefatos com SHA-256 e
identifica explicitamente os testes ainda não realizados no dispositivo.

A fase 4 **só está concluída** quando o job macOS
`Compile real Wine ARM64EC PE and iPhoneOS Unix/wineserver archives`
passar integralmente. Os testes host de CMake, checklists ou mocks não
provam um Wine executável no iPad. Inicialização do wineserver, execução
do guest e encerramento seguro exigem validação física nas fases 7–9.

### Fase 5: DXMT/D3D11 compilado sem o conversor proprietário

Pré-requisitos já aprovados em compilação macOS:
- **Fase 2** — [workflow #40994092326](https://github.com/FacensPedro/iDeck/actions/runs/40994092326), LLVM 15, ARM64EC e dependências públicas.
- **Fase 3** — [workflow #40999473834](https://github.com/FacensPedro/iDeck/actions/runs/40999473834), bibliotecas FEXCore ARM64 e `xtajit64.dll`.
- **Fase 4** — [workflow #41002933976](https://github.com/FacensPedro/iDeck/actions/runs/41002933976), Wine 11.4 ARM64EC, `ntdll.dll`, `libntdll_unix.a`, `libwineserver.a` e `libwin32u_unix.a`. A PR #100 permanece dependência de integração enquanto não estiver mesclada na `main`.

O workflow `.github/workflows/madeira-dxmt-stage5.yml` executa
`IDECK_MADEIRA_GRAPHICS=d3d11 IDECK_BUILD_WOW64=0
IDECK_MADEIRA_STOP_AFTER=dxmt bash scripts/build_madeira_components.sh`.
FEX e Wine são compilados das fontes fixadas e validados antes de chegar
aos shaders Metal do DXMT; após a cópia dos módulos gráficos, a execução
**para antes** da compilação WoW64, D3D12, DirectComposition opcional
e do empacotamento do IPA.

O verificador `scripts/verify_madeira_dxmt_stage5.py` só aprova se:
- `libdxmt_combined.a` for um arquivo de objetos real para iPhoneOS ARM64;
- `d3d11.dll`, `dxgi.dll`, `d3d10core.dll` e `winemetal.dll`
  existirem em **ambas** as famílias PE `aarch64-windows` e `arm64ec-windows`
  com a máquina correta e metadados CHPE quando aplicável;
- os arquivos de configuração Meson/Ninja PE reais e os intermediários
  AIR/cabeçalhos gerados de `air_msad`, `air_samplepos` e
  `air_tessellation` estiverem presentes;
- o recibo `dxmt-stage5-receipt.json` incluir os hashes SHA-256 dos
  **nove** produtos gráficos, sem afirmar execução no dispositivo.

Uma aprovação exige que o **job macOS de compilação DXMT** passe,
não apenas o job de testes host. **Não foi validado** neste estágio
o link final do IPA, a primeira imagem apresentada pelo jogo,
o JIT StikDebug, os controles ou o áudio no iPad.
O perfil D3D11 continua dispensando o Apple Metal Shader Converter
e os arquivos proprietários D3D12.

### Fases 3–5: pontos de parada independentes

Com as toolchains previamente verificadas, em runner Xcode/macos:

```bash
IDECK_MADEIRA_GRAPHICS=d3d11 IDECK_BUILD_WOW64=0 \
  IDECK_MADEIRA_STOP_AFTER=fex bash scripts/build_madeira_components.sh

IDECK_MADEIRA_GRAPHICS=d3d11 IDECK_BUILD_WOW64=0 \
  IDECK_MADEIRA_STOP_AFTER=wine bash scripts/build_madeira_components.sh

IDECK_MADEIRA_GRAPHICS=d3d11 IDECK_BUILD_WOW64=0 \
  IDECK_MADEIRA_STOP_AFTER=all bash scripts/build_madeira_components.sh
```

- **FEX:** requer FEXCore e allocator reais, além do `xtajit64.dll`.
- **Wine:** requer `libntdll_unix.a`, `libwineserver.a`,
  `libwin32u_unix.a` e ntdll ARM64EC efetivamente compilados.
- **DXMT:** requer `libdxmt_combined.a`, `winemetal.dll`, `d3d11.dll`
  e `dxgi.dll` entre os artefatos completos.
- O padrão `IDECK_MADEIRA_STOP_AFTER=all` mantém o build completo.
  Os pontos de parada não são aceitáveis como IPA nativo final.

### Fase 6: link e empacotamento estrito

`IDECK_MADEIRA_GRAPHICS=d3d11 IDECK_REQUIRE_MADEIRA=1` obriga
`build_ipa.sh` a gerar **um IPA realmente nativo** ou falhar. Somente
aprovar após `nm`, `verify_madeira_bundle.py --graphics d3d11 --require`,
auditoria de licenças e integridade do IPA passarem. A opção
`build_native_runtime.sh` agora escolhe D3D11/x86-64 sem WoW64 e
`IDECK_PREBUILT_MODE=off` por padrão. Uma tag D3D11 não pode incluir
`libmetalirconverter.dylib` nem DLLs D3D12.

### Fases 7–11: verificação assinada e teste físico

Há verificações de assinatura/entitlements, JIT ao vivo, ciclo de vida do
Wine, primeiro frame, áudio, controles, repetição de sessões e conformidade.
O documento `docs/MADEIRA_DEVICE_ACCEPTANCE.md` lista evidências exigidas.
Essas fases **não podem ser aprovadas** sem um IPA nativo corretamente
assinado e execução real em iPad compatível. O CI não acessa StikDebug no
dispositivo e não pode provar um frame nem áudio efetivamente apresentados.

### D3D12 e WoW64 posteriores

D3D12 fica **desativado por padrão**: a licença aplicável ao conversor
da Apple precisa ser analisada antes de qualquer redistribuição. Marcar uma
variável de ambiente não concede permissão. WoW64 usa fontes Wine/FEX
diferentes e só pode ser considerado compatível após um teste real PE32.
Não se usam DLLs Microsoft sem os direitos de distribuição aplicáveis.

---

## Fase 1 aprovada — perfil D3D11 estrito e fontes públicas (29/10/2026)

**Escopo desta fase:** permitir selecionar e auditar uma cadeia
`FEX + Wine ARM64EC + DXMT/D3D11` sem redistribuir o Apple Metal Shader
Converter e sem prometer a execução de jogos antes das etapas de compilação,
vinculação e testes físicos. A API do perfil D3D12 original permanece
disponível somente quando selecionada explicitamente e autorizada.

### Seleção do backend

- `IDECK_REQUIRE_MADEIRA=0`: interface apenas; não ativa símbolos nativos.
- `IDECK_REQUIRE_MADEIRA=1 IDECK_MADEIRA_GRAPHICS=d3d11`: modo
  **x86-64/ARM64EC**, sem D3D12, sem `libmetalirconverter.dylib`, sem
  WoW64 (`IDECK_BUILD_WOW64=0`) e sem kit pré-compilado do backend antigo.
- `IDECK_REQUIRE_MADEIRA=1 IDECK_MADEIRA_GRAPHICS=d3d12`: modo legado,
  que continua exigindo `IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1`.
  Essa variável NÃO concede direitos; use-a somente quando o titular
  confirmar que a licença aplicável permite a distribuição prevista.
- Em `workflow_dispatch` do GitHub Actions, selecione
  `require_madeira=true`, `graphics_profile=d3d11`,
  `build_wow64=false` e `accept_converter_license=false`.
  Builds comuns de pull request continuam sendo de interface.

O build de fase 1 que deverá ser executado **após concluir as toolchains e
compilações nativas** da fase 2 em diante é:

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_MADEIRA_GRAPHICS=d3d11 \
IDECK_BUILD_WOW64=0 \
IDECK_PREBUILT_MODE=off \
IDECK_CONFIGURATION=Debug \
bash scripts/build_ipa.sh
```

**Gate estrito para o bundle D3D11 (somente após Xcode construir o .app):**

```bash
python3 scripts/verify_madeira_bundle.py \
  --app build/Staging/iDeck.app --graphics d3d11 --require
```

O verificador exige símbolos e DLLs reais FEX, Wine e DXMT (inclusive
arquitetura ARM64EC), o certificado de CA, o prefixo Wine e as licenças.
Rejeita DLLs D3D12, diretórios `d3d12/` e qualquer
`libmetalirconverter.dylib` incluída no bundle. O manifesto escreve
`graphicsBackend=d3d11` e `d3d12Linked=false`; o iDeck só aceita
o runtime nativo quando esse manifesto e os símbolos correspondem ao perfil.

**Submódulos públicos:** o script `fetch_madeira_sources.sh` agora chama
`verify_madeira_sources.py` depois do clone recursivo e exige SHA exato
para a revisão Madeira, os gitlinks FEX/Wine/DXMT/madeira-dock e o rpmalloc
aninhado. Gitlinks ausentes, alterados ou URLs privadas devem falhar; não
se admite substituir esses forks por fontes upstream genéricas. O workflow
`.github/workflows/madeira-public-sources.yml` verifica o checkout do zero,
sem usar credenciais ou forks privados. As revisões fixadas são verificadas,
não atualizadas automaticamente para o `main` do Madeira.

**Compatibilidade:** kits antigos continuam pertencendo ao perfil D3D12.
Até existir um esquema de kit separado e auditado para D3D11, a opção
`IDECK_PREBUILT_MODE=off` é obrigatória. A verificação de assinatura
`verify_signed_madeira_app.py` também respeita `graphicsBackend`.
Não se deve executar `verify_madeira_bundle.py` *depois* de assinar, pois
ele regrava o manifesto; assinatura e entitlements permanecem para a fase 7.

**Limite conhecido:** as alterações de fase 1 são de seleção, diagnóstico,
fontes e verificação. Elas NÃO provam compilação de LLVM, FEX, Wine ou
DXMT em um runner limpo, ligação final com `nm`, IPA nativo funcional,
JIT operante, primeiro frame Metal, áudio nem encerramento de um
aplicativo Windows no iPad. O primeiro `IDECK_REQUIRE_MADEIRA=1` só
será considerado aprovado quando as fases seguintes fornecerem evidências.

---

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
   versão correta do iOS, confirmar os entitlements no app assinado e
   validar as permissões de memória pela inicialização real do pool JIT;
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
