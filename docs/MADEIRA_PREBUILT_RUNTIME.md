# Runtime Madeira pré-compilado no iDeck

O iDeck agora pode gerar IPAs sem reinstalar ou recompilar FEX, Wine ARM64EC,
DXMT, WineMetal e as bibliotecas nativas do Madeira a cada execução.

**Importante:** o código de preparação e reutilização está implementado.
Ainda não existe nenhum pacote binário compilado na pasta
`runtime/prebuilt/ios-arm64/`. É preciso compilar uma vez e
guardar o resultado. A presença de scripts não significa que o emulador
esteja efetivamente integrado ou funcional no iPad.

## Usar o cache automático do GitHub Actions

Abra Actions → iOS Build → Run workflow, selecione a branch e ative
`require_madeira`. Depois de verificar as condições legais, confirme
separadamente a licença do Apple Metal Shader Converter.

Na primeira execução sem pacote pronto, o workflow compila o runtime e
gera um arquivo em `build/native-cache/`. O `actions/cache` persiste
esse arquivo; nas execuções futuras com as mesmas opções e a mesma versão
dos scripts, o build reutiliza o pacote sem executar o checkout do Madeira,
a instalação do LLVM/Meson ou a compilação das bibliotecas.

O cache pode ser removido ou expirar e possui limitações de capacidade,
escopo de branch e armazenamento. Para persistência, use Git LFS.

## Armazenar permanentemente no próprio repositório

Depois de uma compilação nativa bem-sucedida no Mac, os arquivos podem ter
estes nomes:

| Configuração | Pacote |
| --- | --- |
| Normal | `madeira-base.zip` |
| WoW64 (32 bits) | `madeira-wow64.zip` |
| Wine Mono | `madeira-mono.zip` |
| WoW64 e Wine Mono | `madeira-wow64-mono.zip` |

**Somente se todas as licenças autorizarem a redistribuição** do conteúdo
(inclusive o Apple Metal Shader Converter), coloque um pacote compilado
no repositório usando Git LFS:

```bash
git lfs install
mkdir -p runtime/prebuilt/ios-arm64
cp build/native-cache/madeira-base.zip runtime/prebuilt/ios-arm64/
git add .gitattributes runtime/prebuilt/ios-arm64/madeira-base.zip
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
