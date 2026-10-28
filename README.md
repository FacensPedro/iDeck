# iDeck

**iDeck é um projeto experimental para iOS/iPadOS que reúne biblioteca Steam, aplicativos hospedados e um ambiente de compatibilidade Windows baseado no [Madeira](https://github.com/willfaust/madeira).**

> **Atenção:** um IPA `interface-only` mostra a interface, mas **não executa jogos Windows**. Um IPA `Madeira-native` inclui componentes como FEX, Wine ARM64EC, DXMT, WineMetal e D3D12; concluir a compilação não garante que os jogos funcionem no iPad.

**English:** Experimental iOS/iPadOS Steam library and Windows compatibility project. Native build success does not guarantee game execution. For Microsoft Visual C++ setup, read the [DLL guide (Portuguese, with English summary)](docs/MICROSOFT_VISUAL_CPP_DLLS.md).

[Como compilar](#como-compilar-o-ipa) · [DLLs Microsoft](#bibliotecas-microsoft-visual-c-dlls) · [Problemas comuns](#solução-de-problemas) · [Documentação](#documentação)

## Funcionalidades e limites

| Componente | O que está implementado | O que depende de validação |
| --- | --- | --- |
| Steam | Login, biblioteca de jogos, metadados e downloads | Autenticação exigida por determinados jogos e pelo cliente Windows |
| Windows | Importação de `.exe`, perfis de jogos e Wine prefix | FEX/JIT, Wine e compatibilidade real dos programas |
| Gráficos | Adaptadores Metal, DXMT, WineMetal, D3D12 e opções MetalFX | Apresentação de quadros e desempenho em hardware |
| Aplicativos iOS | Integração inspirada no LiveContainer | Assinatura, entitlements e restrições do iPadOS |
| JIT | Integração com [StikDebug](https://github.com/StikDebug/StikDebug) | O iDeck não ativa JIT por conta própria nem contorna a segurança do iPadOS |
| Runtime reutilizável | Cache e kits pré-compilados do Madeira | Compilar um kit nativo real uma vez e respeitar suas licenças |

O iDeck utiliza SwiftUI, C/C++, Objective-C++, Wine e interfaces Metal. Os adaptadores do projeto não substituem um runtime Windows completo.

## Requisitos

- **Para compilar:** macOS, Xcode com SDK de iOS/iPadOS 27 e ferramentas nativas adequadas.
- **Para instalar:** IPA assinado para o seu dispositivo com provisionamento e permissões apropriados.
- **Para jogos Windows:** IPA nativo, Wine prefix funcional, componentes gráficos e JIT compatível.
- **Para programas Windows de 32 bits:** build opcional com WoW64; não é garantia de compatibilidade.

O alvo mínimo atual do projeto é **iOS/iPadOS 27.0**.

## Como compilar o IPA

### Pelo GitHub Actions

1. Abra [Actions → iOS Build](https://github.com/FacensPedro/iDeck/actions/workflows/ios.yml).
2. Escolha uma branch e clique em **Run workflow**.
3. Para testar **somente a interface**, desmarque `Require Madeira runtime`.
4. Para criar o IPA **nativo**, deixe `Require Madeira runtime` ativado e selecione WoW64 ou Wine Mono somente quando necessário.
5. Verifique os termos do **Apple Metal Shader Converter**; confirme o aceite somente se tiver autorização para o uso e a distribuição pretendidos.
6. Após o sucesso do workflow, confira o nome do artefato: `iDeck-interface-only` ou `iDeck-Madeira-native`.

Os builds automáticos de push/PR podem gerar apenas a interface. **Nunca confunda o IPA interface-only com um emulador Windows funcional.**

### Pelo Mac

Somente interface:

```bash
bash scripts/build_ipa.sh
```

Build nativo (com ferramentas preparadas e autorização de licença):

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
bash scripts/build_native_runtime.sh
```

O arquivo gerado é `iDeck.ipa` quando todas as etapas passam. Configure os próprios Bundle IDs, App Group, Team ID e permissões para a assinatura do IPA.

### Evitar recompilar FEX, Wine e DXMT

O iDeck reutiliza pacotes de runtime existentes no Git LFS ou cache do build. Para **não baixar nem recompilar** os componentes, exija um kit disponível:

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
IDECK_PREBUILT_MODE=only \
bash scripts/build_ipa.sh
```

Sem kit válido, esse comando falha em vez de criar um runtime fictício. Veja o [guia de runtime pré-compilado](docs/MADEIRA_PREBUILT_RUNTIME.md).

## Bibliotecas Microsoft Visual C++ (DLLs)

Jogos Windows podem depender de bibliotecas como `vcruntime140.dll`, `msvcp140.dll` e `msvcp140_1.dll`. **O iDeck não baixa nem inclui DLLs proprietárias da Microsoft automaticamente.**

### Onde obter

- **[Microsoft — downloads oficiais do Visual C++](https://learn.microsoft.com/pt-br/cpp/windows/latest-supported-vc-redist)**, incluindo o instalador [`vc_redist.x64.exe`](https://aka.ms/vc14/vc_redist.x64.exe).
- **[Microsoft — localização dos arquivos DLL redistribuíveis](https://learn.microsoft.com/en-us/cpp/windows/determining-which-dlls-to-redistribute)**, normalmente nas pastas de redistribuição x64 do Visual Studio com MSVC instalado.
- **[Microsoft — termos para redistribuir bibliotecas Visual C++](https://learn.microsoft.com/pt-br/cpp/windows/redistributing-visual-cpp-files)**.

> **Diferença importante:** `vc_redist.x64.exe` é um **instalador para Windows**, não uma DLL para copiar ao iPad. Para o Wine, você deve fornecer os arquivos `.dll` x64 reais, obtidos de uma fonte confiável e com direitos de uso adequados. Não baixe DLLs de sites desconhecidos.

### Instalar no iDeck

1. Abra **Settings → Windows compatibility → Prepare Visual C++ folder**.
2. Obtenha os arquivos **DLL Windows x64**, conforme o [guia detalhado](docs/MICROSOFT_VISUAL_CPP_DLLS.md).
3. Transfira os arquivos pelo iCloud Drive, armazenamento externo ou [Apple Devices](https://support.apple.com/guide/devices-windows/transfer-files-between-your-devices-mchl4bd77d3a/windows).
4. No iPad, mova os arquivos para **Arquivos → No Meu iPad → iDeck → vcruntime**.
5. Feche completamente o iDeck e abra-o novamente.

```text
No Meu iPad/
└── iDeck/
    └── vcruntime/
        ├── vcruntime140.dll
        ├── msvcp140.dll
        └── msvcp140_1.dll
```

Os nomes acima são **exemplos**: o jogo pode precisar de outras bibliotecas. Isso não instala o Redistributable completo nem resolve automaticamente falhas de FEX, Wine ou Metal.

**[Tutorial completo: baixar, localizar, selecionar e transferir DLLs Microsoft Visual C++](docs/MICROSOFT_VISUAL_CPP_DLLS.md)**

## Solução de problemas

| Sintoma | O que conferir |
| --- | --- |
| O jogo nem inicia | IPA nativo, prefixo Wine, JIT e dependências do programa |
| Tela preta | Inicialização Wine/FEX, DXMT, contador de quadros e apresentação Metal |
| Erro de `vcruntime140.dll` ou `msvcp140.dll` | DLLs x64 corretas na pasta `vcruntime` e compatibilidade com o jogo |
| O instalador `vc_redist.x64.exe` não abre no iPad | Ele instala o redistribuível no Windows, não no iPadOS |
| Jogo de 32 bits | IPA com WoW64, se disponível e funcional |
| GitHub Actions terminou com erro | Leia o primeiro `ERROR` real; `BUILD SUCCEEDED` no Xcode não significa que o IPA final foi empacotado |
| iDeck fecha após alguns minutos | Analise o relatório `.ips` completo; não conclua que Metal é a causa apenas pela tela preta |

O indicador de JIT não prova que o FEX conseguiu inicializar suas páginas executáveis. Veja o [guia de diagnóstico de jogos](docs/IDECK_GAME_STARTUP_DIAGNOSTICS.md).

## Documentação

- [Microsoft Visual C++ no iDeck — guia completo](docs/MICROSOFT_VISUAL_CPP_DLLS.md)
- [Runtime Madeira pré-compilado](docs/MADEIRA_PREBUILT_RUNTIME.md)
- [Diagnóstico de inicialização e tela preta](docs/IDECK_GAME_STARTUP_DIAGNOSTICS.md)
- [Status de integração do Madeira](docs/MADEIRA_RUNTIME_INTEGRATION.md)
- [Build nativo do Madeira](docs/IDECK_MADEIRA_NATIVE_BUILD.md)
- [Link e verificação nativos](docs/MADEIRA_NATIVE_LINKING.md)
- [Módulos nativos](docs/NATIVE_RUNTIME_MODULES.md)
- [Memória no iPadOS](docs/IOS_MEMORY_MANAGEMENT.md)
- [Desempenho](docs/NATIVE_PERFORMANCE.md)
- [Downloads da Steam](docs/STEAM_DOWNLOAD_PERFORMANCE.md)

## Licenças, segurança e créditos

O iDeck integra ou adapta componentes de [Madeira](https://github.com/willfaust/madeira), [FEX](https://github.com/FEX-Emu/FEX), [Wine](https://www.winehq.org/), [DXMT](https://github.com/3Shain/dxmt), [StikDebug](https://github.com/StikDebug/StikDebug) e [LiveContainer](https://github.com/LiveContainer/LiveContainer). Consulte os arquivos de [licença](LICENSES) e os avisos dos respectivos projetos.

**Não publique DLLs Microsoft, ferramentas proprietárias Apple ou IPAs que as contenham sem confirmar os direitos de redistribuição correspondentes.** Não forneça logs com credenciais ou tokens Steam.

Para contribuir ou reportar problemas, informe versão do iPadOS, dispositivo, nome do jogo, tipo de IPA e logs relevantes, retirando dados privados.

---

**iDeck é experimental. Uma compilação bem-sucedida não representa garantia de compatibilidade com jogos Windows no iPad.**
