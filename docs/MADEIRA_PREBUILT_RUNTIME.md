# Runtime Madeira pré-compilado no iDeck

O iDeck agora pode gerar IPAs sem reinstalar ou recompilar FEX, Wine ARM64EC,
DXMT, WineMetal e as bibliotecas nativas do Madeira a cada execução.

**Importante:** o código de preparação e reutilização está implementado.
Ainda não existe nenhum pacote binário compilado na pasta
`runtime/prebuilt/ios-arm64/`. É preciso compilar uma vez e
guardar o resultado. A presença de scripts não significa que o emulador
esteja efetivamente integrado ou funcional no iPad.

## Usar o cache automático do GitHub Actions

Abra Actions → iOS Build → Run workflow e selecione a branch:
`require_madeira=on`, `graphics_profile=d3d11`,
`build_wow64=on`, `bundle_wine_mono=off`,
`accept_converter_license=off`, `export_runtime_kit=off`, `release_tag` vazio.
O perfil D3D11 é público e **não requer o Metal Shader Converter**.
Somente o perfil D3D12 exige confirmação explícita das condições da Apple;
sem isso, a compilação falha com exit 2.

Na primeira execução sem pacote pronto, o workflow compila o runtime e
gera um arquivo em `build/native-cache/`. O `actions/cache` persiste
esse arquivo; nas execuções futuras com as mesmas opções e a mesma versão
dos scripts, o build reutiliza o pacote sem executar o checkout do Madeira,
a instalação do LLVM/Meson ou a compilação das bibliotecas.

O cache D3D11 e o cache D3D12 são separados e vinculados às opções
WoW64/Mono e aos hashes dos scripts e patches nativos. O verificador do kit
impede usar um pacote D3D12 no perfil D3D11 e rejeita o conversor e os
módulos PE D3D12 no kit público. A primeira execução compila os componentes
nativos; uma segunda execução com as mesmas opções pode reutilizar o kit
desde que o cache tenha sido salvo e sua inspeção seja aprovada.

O cache pode ser removido ou expirar e possui limitações de capacidade,
escopo de branch e armazenamento. Para persistência autorizada, use Git LFS.

### Exportar um kit compilado pelo próprio GitHub Actions

O workflow manual também oferece `export_runtime_kit`. Ative apenas quando
você tiver confirmado o direito de redistribuir **todos** os binários incluídos,
principalmente o Apple Metal Shader Converter. Ao terminar o build nativo, o
GitHub disponibilizará por sete dias o artefato
`iDeck-Madeira-precompiled-runtime`, contendo o ZIP compatível com as opções
de build selecionadas. Extraia o ZIP desse artefato no seu computador antes
de colocá-lo na pasta do projeto com Git LFS. A exportação é **desativada**
por padrão. Em repositórios públicos, confira quem pode acessar os artefatos
e se o licenciamento permite esse compartilhamento.

## Armazenar permanentemente no próprio repositório

WoW64 é habilitado por padrão nas compilações nativas. Para D3D12, o kit `madeira-base.zip` é destinado à opção `IDECK_BUILD_WOW64=0`. Para D3D11, os pacotes usam o sufixo `-d3d11` e não incluem o Metal Shader Converter. O nome do pacote deve corresponder aos binários efetivamente compilados.

Depois de uma compilação nativa bem-sucedida no Mac, os arquivos podem ter
estes nomes:

| Configuração | Pacote |
| --- | --- |
| Nativo padrão (inclui WoW64 de 32 bits) | `madeira-wow64.zip` |
| Somente 64 bits (`IDECK_BUILD_WOW64=0`) | `madeira-base.zip` |
| Somente 64 bits + Wine Mono | `madeira-mono.zip` |
| WoW64 + Wine Mono | `madeira-wow64-mono.zip` |
| D3D11 com WoW64 (padrão do Actions) | `madeira-wow64-d3d11.zip` |
| D3D11 somente 64 bits | `madeira-base-d3d11.zip` |
| D3D11 com WoW64 e Mono | `madeira-wow64-mono-d3d11.zip` |

**Somente se todas as licenças autorizarem a redistribuição** do conteúdo
(inclusive o Apple Metal Shader Converter), coloque um pacote compilado
no repositório usando Git LFS:

```bash
git lfs install
mkdir -p runtime/prebuilt/ios-arm64
cp build/native-cache/madeira-wow64.zip runtime/prebuilt/ios-arm64/
git add .gitattributes runtime/prebuilt/ios-arm64/madeira-wow64.zip
git commit -m "Add precompiled Madeira runtime"
git push
```

Use o nome correspondente às opções com que compilou. Não use um arquivo
LFS que seja apenas um ponteiro sem que o objeto binário tenha sido enviado.
Atenção aos limites de tamanho, tráfego e armazenamento do GitHub LFS.
**Não publique o conversor proprietário num repositório público sem permissão.**

Para criar o kit em uma compilação local (macOS/Xcode 27, dependências nativas
preparadas e permissões adequadas):

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
IDECK_PREBUILT_MODE=off \
IDECK_PREBUILT_EXPORT=1 \
bash scripts/build_native_runtime.sh
```

Para criar um novo IPA SEM recompilar os componentes:

```bash
IDECK_REQUIRE_MADEIRA=1 \
IDECK_ACCEPT_METAL_CONVERTER_LICENSE=1 \
IDECK_PREBUILT_MODE=only \
bash scripts/build_ipa.sh
```

`only` falha imediatamente se o pacote não existir.
`prefer` (padrão) utiliza o kit do repositório, depois o cache, e
só compila se nenhum estiver disponível.
`off` obriga recompilar tudo.

Os kits contêm bibliotecas estáticas ARM64, módulos Windows, Wine prefix,
recursos de TLS, DLLs D3D11/D3D12 e arquivos de licença. O instalador confere
revisão do Madeira, opções WoW64/Mono, caminhos internos e SHA-256 de cada
arquivo; o IPA continua sendo validado por `verify_madeira_bundle.py`.

Isso reduz downloads e recompilações do CI, mas não substitui a assinatura
correta, JIT/StikDebug nem o teste de um jogo no iPad.

**Compatibilidade das revisões:** após incorporar correções de alinhamento do wineserver, áudio e VC++ na compilação nativa, os kits pré-compilados antigos não contêm essas alterações. Recompile o kit e atualize-o no Git LFS; o cache Actions inclui o hash da pasta `patches/` para evitar reutilizar o cache nativo anterior.

O empacotador ignora arquivos vazios de marcação de diretórios (por exemplo `i386-windows/.gitkeep`) e metadados incidentais `.DS_Store`. Todos os arquivos de runtime obrigatórios continuam sujeitos à verificação de presença, tamanho e integridade.
