# iDeck: download direto, atualizações e log do Wine

## Baixar o iDeck.ipa sem ZIP externo

O workflow `.github/workflows/ios.yml` publica **iDeck.ipa** usando
`actions/upload-artifact@v7` com `archive: false`.

Ao concluir o workflow, abra a página da execução no GitHub Actions e clique
em **iDeck.ipa** na seção de artefatos. O navegador baixa a IPA diretamente,
sem um arquivo `.zip` adicional. A IPA, por definição, já é um arquivo no
formato ZIP com `Payload/iDeck.app` dentro; não modifique sua extensão.

Os artefatos do GitHub Actions são temporários (retenção de 30 dias) e podem
exigir autenticação no GitHub. Eles **não** são destinados a serem usados como
URLs de instalação automática para SideStore ou AltStore.

O workflow também pode publicar uma IPA direta como ativo permanente de
**GitHub Release** quando executado com o runtime nativo, licença apropriada
e uma tag de release. Na aba Actions, rode `iOS Build`, confirme que você
possui direitos sobre os componentes empacotados e informe `release_tag`
(por exemplo, `v0.2.0`). É necessário aumentar a versão do aplicativo ao
publicar uma atualização, de modo que o verificador identifique a nova
versão. Não publique componentes cuja licença não autoriza distribuição.

## Botão Atualizar iDeck

Em **Configurações > Atualizações**, toque em **Verificar atualizações**.
O iDeck consulta as GitHub Releases e procura uma versão mais recente com
uma IPA publicada. Quando existir, **Atualizar iDeck** abre o SideStore ou
AltStore com o endereço HTTPS verificado da IPA. Se nenhum dos dois aceitar
o link, abre a página oficial de releases para instalação manual.

O iPadOS não permite que o aplicativo substitua seu próprio executável
instalado, evite a assinatura exigida ou instale uma atualização no lugar
de um aplicativo com outra identidade de assinatura. Conclua a instalação
no gerenciador usado originalmente. O mesmo bundle ID e uma assinatura
compatível normalmente preservam o contêiner de dados; instaladores e
políticas de assinatura podem exigir outro procedimento. Mantenha backup
de saves importantes e **não apague o iDeck antes de atualizar**.

## Copiar log do Wine

Na tela do Wine, o ícone de copiar e o botão **Copiar log do Wine** enviam
os logs de `Documents/madeira-log.txt` diretamente para a área de
transferência. Não é necessário procurar o arquivo no app Arquivos.

Se o log ultrapassar **4 MiB**, o iDeck copia apenas as mensagens mais
recentes e informa que o resultado foi reduzido para evitar alto uso de
memória. Use **Compartilhar log do Wine** para exportar o arquivo completo.

Os logs podem conter caminhos pessoais, nomes de usuários e tokens.
Revise o conteúdo antes de colar ou compartilhar. A leitura não inicia
o Wine, não solicita JIT e não altera dados do jogo.
