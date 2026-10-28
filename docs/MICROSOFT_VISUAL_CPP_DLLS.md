> **Automatic first-game setup:** Current iDeck builds can offer to download the **official Microsoft x64 Visual C++ Redistributable** on the first Windows game launch and attempt to install it inside Wine. This requires your confirmation and a compatible Wine/WoW64 runtime; it is not guaranteed to work. The steps below remain a manual alternative if installation fails.

# Microsoft Visual C++ no iDeck — guia de DLLs Windows x64

Este guia mostra como **obter arquivos oficiais**, **identificar as DLLs corretas** e **transferi-las ao iDeck**. O processo para usuários do iPad é diferente da inclusão das bibliotecas dentro de um IPA.

> **Licenças:** a Microsoft condiciona a redistribuição dos binários do Visual C++ aos termos do Visual Studio e a direitos específicos. Obter o instalador oficial **não autoriza automaticamente republicar as DLLs**. Não envie DLLs proprietárias a repositórios públicos, arquivos de release ou pacotes compartilhados sem verificar os termos aplicáveis.

## 1. O que baixar

| Arquivo | Finalidade |
| --- | --- |
| `vc_redist.x64.exe` | Instalador oficial das bibliotecas Visual C++ para **Windows x64** |
| `vc_redist.x86.exe` | Instalador para programas Windows **de 32 bits** |
| `vcruntime140.dll`, `msvcp140.dll` e semelhantes | Bibliotecas efetivamente carregadas pelo programa Windows |

**Download oficial da Microsoft:**

- [Visual C++ Redistributable — última versão com suporte](https://learn.microsoft.com/pt-br/cpp/windows/latest-supported-vc-redist)
- [Link direto oficial para x64: vc_redist.x64.exe](https://aka.ms/vc14/vc_redist.x64.exe)
- [Arquivos redistribuíveis do Visual Studio](https://learn.microsoft.com/en-us/cpp/windows/determining-which-dlls-to-redistribute)
- [Condições de redistribuição Microsoft](https://learn.microsoft.com/pt-br/cpp/windows/redistributing-visual-cpp-files)

Se você **executar** o instalador no Windows do PC, as bibliotecas serão instaladas **no Windows do PC**, não no Wine do iDeck. Para o iPad, o que deve ser transferido são as **DLLs reais**, quando seu uso estiver autorizado.

## 2. Onde encontrar as DLLs individuais no Windows

A Microsoft documenta que arquivos redistribuíveis individuais podem estar presentes em uma instalação licenciada do **Visual Studio com ferramentas de C++** (MSVC). Abra o **Developer PowerShell for Visual Studio** e verifique a pasta da variável `VCToolsRedistDir`:

```powershell
$env:VCToolsRedistDir
```

Geralmente, os arquivos estão em subpastas como:

```text
%VCToolsRedistDir%
└── x64
    ├── Microsoft.VC143.CRT
    │   ├── vcruntime140.dll
    │   └── msvcp140.dll
    └── Microsoft.VC143.MFC
        ├── mfc140.dll
        └── mfc140u.dll
```

`VC143` é um **exemplo**; a pasta varia com a versão das ferramentas. As DLLs MFC podem exigir componentes opcionais do Visual Studio. A instalação isolada de `vc_redist.x64.exe` **não garante** a existência desse diretório de desenvolvimento.

### Copiar os arquivos disponíveis com PowerShell

Se você possui acesso autorizado aos arquivos redistribuíveis no Visual Studio, execute no **Developer PowerShell for Visual Studio**:

```powershell
$sourceRoot = $env:VCToolsRedistDir
if (-not $sourceRoot) {
    throw "Abra o Developer PowerShell e instale o componente MSVC C++."
}

$x64Root = Join-Path $sourceRoot "x64"
if (-not (Test-Path -LiteralPath $x64Root)) {
    throw "A pasta de DLLs x64 do Visual Studio não foi encontrada."
}

$destination = Join-Path $env:USERPROFILE "Desktop\iDeck-vcruntime"
New-Item -ItemType Directory -Path $destination -Force | Out-Null

$names = @(
    "concrt140.dll",
    "msvcp140.dll",
    "msvcp140_1.dll",
    "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll",
    "msvcp140_codecvt_ids.dll",
    "vcamp140.dll",
    "vccorlib140.dll",
    "vcomp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
    "vcruntime140_threads.dll",
    "mfc140.dll",
    "mfc140u.dll"
)

foreach ($name in $names) {
    $file = Get-ChildItem -LiteralPath $x64Root -Recurse -File -Filter $name |
        Select-Object -First 1
    if ($null -eq $file) {
        Write-Warning "DLL não encontrada nesta instalação: $name"
        continue
    }
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destination $name)
    Write-Host "Copiado: $name"
}

Write-Host "Arquivos em: $destination"
```

O comando **não baixa DLLs** nem contorna os direitos de uso; ele organiza as DLLs que já estejam presentes na instalação. Nem toda instalação contém os 14 arquivos. Bibliotecas MFC e outras podem precisar de componentes opcionais. Para o iPad, o jogo só precisa das DLLs efetivamente utilizadas, desde que legalmente disponíveis e compatíveis.

**Não misture DLLs Windows x86, x64 e ARM64.** A pasta `vcruntime` documentada nesta integração é destinada às DLLs **Windows x64**, mesmo que o iPad utilize processador ARM64.

## 3. Transferir as DLLs para o iDeck no iPad

1. Instale e abra o iDeck pelo menos uma vez.
2. Acesse **Settings → Windows compatibility → Prepare Visual C++ folder**. A ação cria a pasta `vcruntime`.
3. Transfira os arquivos DLL x64 para o iPad pelo iCloud Drive, armazenamento externo ou **Apple Devices** no Windows.
4. Pelo app **Arquivos**, mova os arquivos para **No Meu iPad → iDeck → vcruntime**.
5. Feche completamente o iDeck e abra-o novamente antes de iniciar o jogo.

```text
No Meu iPad/
└── iDeck/
    └── vcruntime/
        ├── vcruntime140.dll
        ├── msvcp140.dll
        └── msvcp140_1.dll
```

Os nomes mostrados são exemplos. Não copie `vc_redist.x64.exe` para essa pasta: **o instalador não é uma DLL**.

### Transferência pelo Apple Devices (Windows)

A Apple documenta o compartilhamento de arquivos entre Windows e iPad:

1. Abra o aplicativo **Apple Devices** no computador e conecte o iPad.
2. Selecione o dispositivo, depois **Files/Arquivos → iDeck**.
3. Envie os arquivos à área de documentos do iDeck.
4. Se os arquivos forem transferidos para a raiz dos documentos, **mova-os no app Arquivos do iPad para a subpasta `vcruntime`**.

[Instruções oficiais da Apple](https://support.apple.com/guide/devices-windows/transfer-files-between-your-devices-mchl4bd77d3a/windows).

O iDeck define `UIFileSharingEnabled` e `LSSupportsOpeningDocumentsInPlace` no arquivo Info.plist. A disponibilidade do compartilhamento pode depender de como o aplicativo foi instalado e assinado.

## 4. Para desenvolvedores: adicionar DLLs ao IPA

**Esta opção é diferente da pasta `Documents/vcruntime`.** Para colocar as DLLs dentro do aplicativo durante a compilação, o script `scripts/stage_madeira_payload.sh` aceita:

- `IDECK_VCRUNTIME_DIR`: pasta com as DLLs x64 autorizadas.
- `IDECK_REQUIRE_VCRUNTIME=1`: exige que o conjunto Microsoft esteja disponível e completo.

Quando existe uma pasta de origem, o empacotador exige **os 14 nomes** usados no exemplo PowerShell. Se faltar qualquer um, o build falha com `incomplete Microsoft VC++ runtime`. Se a pasta estiver ausente e `IDECK_REQUIRE_VCRUNTIME` não estiver ativado, o build pode continuar com um **aviso**.

Exemplo em um Mac configurado para compilação nativa:

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
IDECK_REQUIRE_VCRUNTIME=1 \
IDECK_VCRUNTIME_DIR="/caminho/para/dlls-x64-autorizadas" \
bash scripts/build_ipa.sh
```

**Não coloque DLLs Microsoft em um IPA público, no Git LFS público ou nos artefatos públicos do Actions sem autorização apropriada.** Consulte também os termos do Apple Metal Shader Converter.

## 5. Problemas comuns

| Problema | Significado e solução |
| --- | --- |
| `vc_redist.x64.exe` não funciona no iPad | É um instalador Windows; forneça as DLLs individuais, quando autorizado |
| `vcruntime140.dll` ausente | Verifique se o jogo necessita da biblioteca e se o arquivo x64 está em `Documents/vcruntime` |
| `msvcp140.dll` ausente | Verifique se você possui a DLL correta, da mesma arquitetura e versão adequada |
| `WARNING: Microsoft VC++ runtime absent` | Pode ser só um aviso no build, caso a inclusão Microsoft não tenha sido exigida |
| `incomplete Microsoft VC++ runtime` | A pasta configurada para o empacotamento existe, mas não contém todos os 14 arquivos obrigatórios |
| Tela preta mesmo com as DLLs | Investigue Wine/FEX, JIT, DXMT/D3D12, Metal e dependências Steam; DLLs não substituem esses componentes |

Sites de DLL avulsas são arriscados: podem conter arquivos adulterados, versões erradas ou distribuídos sem licença. Prefira fontes oficiais.

## English summary

`vc_redist.x64.exe` is Microsoft's official **Windows installer**, not a DLL to copy to iPadOS. With the appropriate rights, locate Windows **x64 DLLs** in a Visual Studio/MSVC redistributable directory and transfer the files you need to **Files → On My iPad → iDeck → vcruntime**. Restart iDeck before testing. For IPA builds, `IDECK_VCRUNTIME_DIR` is a separate developer option requiring the complete 14-DLL set and appropriate redistribution rights.

Official references: [Microsoft downloads](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist), [DLL locations](https://learn.microsoft.com/en-us/cpp/windows/determining-which-dlls-to-redistribute), [Microsoft licensing](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files), [Apple Devices file sharing](https://support.apple.com/guide/devices-windows/transfer-files-between-your-devices-mchl4bd77d3a/windows).
