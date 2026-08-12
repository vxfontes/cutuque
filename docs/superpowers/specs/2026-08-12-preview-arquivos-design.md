# Preview de arquivos na aba Máquinas — desenho

**Data:** 12/08/2026 · **Card:** `789e917e86210bde`

## O pedido

> "a visualização dos arquivos lá da máquina -> dar pra ver preview de foto, video, md, json,
> todo tipo de arquivo de texto, pdf e tal"

E, logo depois:

> "os arquivos de texto será que tem como a gnt deixar com corzinha? tipo md, .ts e tal"

## O que a investigação achou antes do desenho

**O hub já entrega os bytes.** `GET /machines/{machine}/fs/download` existe desde a aba Máquinas
(`server.go:160` → `FileDownloadHandler` → `cat` por ssh), devolve **bytes crus inclusive de
binário**, e o app já consome: `APIClient.downloadFile` grava num diretório temporário **com o nome
original preservado** e devolve a `URL` local. Hoje essa URL só alimenta um `ShareLink`.

Isso decide o tamanho da leva: **preview é extensão, não construção** — mesmo padrão da leva das
abas ("o hub não precisa mudar pra lista agrupada"). O nome preservado importa mais do que parece: o
QuickLook escolhe o renderizador pela **extensão**, então `foto.png` no tmp já abre como foto.

**O que existe hoje** (`FileViewerView.swift`, 162 linhas):

| Caso | Comportamento atual |
|---|---|
| Texto ≤ 1 MiB | `Text` monoespaçado, selecionável, editável, `ShareLink` do conteúdo |
| Binário (byte nulo nos primeiros 8 KiB) | `ContentUnavailableView` "Arquivo binário" + botão Baixar |
| Texto > 1 MiB | `ContentUnavailableView` "Arquivo grande demais" + botão Baixar |

Nenhuma foto, nenhum PDF, nenhum vídeo aparece — e é literalmente o que ela pediu.

**Duas restrições reais**, achadas no código, que moldam o desenho:

1. **O download não tem teto em lugar nenhum.** `DownloadFile` faz `cmd.Output()` — o arquivo
   inteiro vai para a memória do hub — e o handler faz `w.Write(data)`. Um vídeo de 2 GB não é
   lentidão: é o hub do macmini caindo e levando board, sessões e terminais junto. Preview de vídeo
   sem tratar isso é armadilha, não recurso.
2. **Não há `Range`.** `Content-Type` é sempre `application/octet-stream` com `attachment`. Vídeo só
   toca depois de baixar inteiro; arrastar a linha do tempo antes disso não existe.

**De graça:** QuickLook, PDFKit e AVKit são frameworks do sistema — nenhuma dependência nova. O app
tem **uma** dependência externa no total (SwiftTerm), e isso é patrimônio.

## Decisões da Vanessa (4, por pergunta direta)

1. **QuickLook para todos os binários** — um componente cobre foto, vídeo, áudio, PDF, Office,
   iWork, zip, e o "e tal" que ela não listou. Descartados: visualizador nativo por tipo (mais
   controle, muito mais código, e cada tipo novo vira trabalho novo) e o híbrido.
2. **Teto de 50 MB + o hub deixa de bufferizar.** Acima do teto o app pergunta antes de baixar.
   Descartado o `Range`/streaming de verdade (uma fase a mais mexendo no hub que está em produção) e
   descartado "sem teto".
3. **Markdown renderizado + JSON formatado** — e, no segundo pedido, **realce de sintaxe** para
   arquivo de texto em geral.
4. **Texto acima do teto abre a cauda** (~200 KB do fim, com aviso), em vez de não abrir. É o
   pedaço que importa num log.

## Como cada arquivo abre

| Tipo | Comportamento |
|---|---|
| Foto, vídeo, áudio, PDF, zip, Office/iWork | QuickLook embutido na tela, gestos do sistema |
| `.md` | Renderizado (reusa `MarkdownText` do chat); botão "ver fonte" mostra o original colorido |
| `.json` | Indentado e colorido |
| `.ts .tsx .js .swift .go .py .rb .rs .java .kt .c .h .cpp .sh .yaml .yml .toml .sql .html .css` | Colorido |
| Texto sem linguagem conhecida | Monoespaçado, como hoje |
| Texto acima do teto | Cauda (~200 KB do fim) com aviso; baixar o inteiro continua ali |

## O realce, e por que sem dependência

As opções prontas para iOS ou cobrem **uma** linguagem (`Splash`, só Swift) ou embutem o
highlight.js dentro do JavaScriptCore (`Highlightr`) — peso e latência desproporcionais para ler um
arquivo no celular, num app com uma dependência externa no total.

O realce é um **tokenizador próprio**: comentário de linha, comentário de bloco, texto entre aspas
com escape, número, palavra-chave, tipo. A linguagem entra como **conjunto de palavras-chave +
marcadores de comentário e aspas**, então acrescentar linguagem é acrescentar dado, não código. Não
é um compilador e não vai acertar todo caso exótico; para ler código no celular acerta o que
importa, e é **função pura** — entra em XCTest como o resto do projeto.

**A restrição que vem da leva do copiar:** o realce sai como **um `AttributedString` num único
`Text`**. Quebrar em um `Text` por linha (o jeito fácil de colorir) mataria a seleção de texto
exatamente como o `MarkdownText` mata no chat — o bug que ela acabou de mandar consertar. Por isso o
realce tem **teto próprio (200 KiB)**: acima disso o arquivo abre sem cor e continua selecionável.
Cor é conforto; conseguir copiar é o pedido anterior dela, e ganha.

## O contrato da cauda

`fs/read` passa a devolver, para arquivo de **texto** acima de `maxReadBytes`, os **últimos 200 KiB**
em vez de conteúdo vazio:

```json
{"path": "...", "size": 5242880, "binary": false, "truncated": true, "tail": true, "content": "…"}
```

- `tail` é **campo novo**; `truncated` continua significando "não veio inteiro".
- Binário segue com `content` vazio e `tail` ausente/`false` — o corte de binário é anterior.
- A cauda começa **depois da primeira quebra de linha** encontrada: cortar por byte no meio de um
  caractere UTF-8 produziria lixo na primeira linha.
- No app, `FileContent.tail` é **`Bool?`**, não `Bool`. O hub só passa a mandar o campo depois do
  deploy, e um `Bool` não-opcional com chave ausente **derruba o decode inteiro** — o visualizador
  de arquivo pararia de funcionar contra o hub de produção até ela subir o hub.

## O teto de 50 MB

O tamanho **já vem na listagem** (`FileEntry.size`), então a decisão acontece **antes de qualquer
byte sair da máquina** — nada de descobrir o tamanho baixando.

- ≤ 50 MB: baixa e mostra o preview direto.
- \> 50 MB: mostra tamanho e um botão explícito ("Baixar assim mesmo (1,2 GB)"). Nada automático.

Do lado do hub, o download passa a ser **repassado em fluxo** (`StdoutPipe` + `io.Copy`) em vez de
bufferizado. Isso não é otimização: é o que impede um arquivo grande de derrubar o hub inteiro.

## O iPad, e a decisão #19

Aba montada fica montada **para sempre**, e `.onDisappear` **nunca dispara** lá dentro. Sem cuidado,
trocar de aba deixa o **vídeo tocando** — invisível e audível. O `FileViewerView` passa a receber o
`isActive` que o `FileBrowserView` já recebe, e o preview é desmontado quando a aba sai de foco.

Este é o mesmo tipo de armadilha que produziu "painel branco" e "Sessão encerrada" na leva das abas:
com aba eterna, **ciclo de vida vira estado explícito**.

## O que este desenho NÃO faz

Apagar, mover ou subir arquivo (a regra "sem destrutiva" da aba Máquinas segue valendo), editar
binário, `Range`/seek em vídeo, cache de download entre aberturas, e miniatura na listagem (a lista
não baixa nada — continua sendo nome, tamanho e data).

## Riscos assumidos

- **Vídeo grande dentro do teto** (ex.: 45 MB) baixa inteiro antes de tocar: espera real, com
  progresso. Aceito nesta leva; `Range` resolveria e ficou fora.
- **O realce vai errar** em caso exótico (string com aspa escapada dentro de comentário, template
  literal com interpolação). Erra pintando de menos, nunca escondendo texto.
- **A cauda muda o significado da tela "Arquivo grande demais"**: ela deixa de existir para texto.
