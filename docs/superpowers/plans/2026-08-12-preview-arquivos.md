# Preview de arquivos — plano de implementação

> **Para quem executa:** cada task roda num worktree próprio, tem ciclo de teste próprio e termina em
> commit. O desenho está em `docs/superpowers/specs/2026-08-12-preview-arquivos-design.md` — leia
> antes. Card do board: `789e917e86210bde`.

**Objetivo:** ver na aba Máquinas o conteúdo dos arquivos da máquina — foto, vídeo, PDF e demais
binários pelo QuickLook; markdown renderizado; JSON formatado; código com realce de sintaxe; e o fim
dos arquivos de texto grandes.

**Base:** branch `arquivos-base` (descende de `copiar-base`, que traz `MarkdownText` com botão de
copiar e as correções da leva do copiar).

## Restrições globais

- **pt-BR** em nome, comentário, teste e texto de tela. Comentário explica **por quê**, não o quê.
- **Nunca apagar** comentário que documenta bug ou decisão de arquitetura. Se a mudança o tornou
  falso, **reescreva** com a razão nova e a data (12/08/2026).
- `git add` **com caminho explícito**, nunca `git add -A` / `git add .`. Não commitar
  `app/CutuqueAppNoWatch.xcodeproj/`, `app/project-notest-watch.yml`, `app/Local.xcconfig`,
  `scripts/tmx.sh`. **Não dar push. Não mexer em branch alheia.**
- **Build do app:** o runtime do watchOS está quebrado na máquina; use SEMPRE
  `app/CutuqueAppNoWatch.xcodeproj` com o scheme **`CutuqueApp`**. Arquivo `.swift` novo ou renomeado
  exige, em `app/`: `xcodegen generate && xcodegen generate --spec project-notest-watch.yml`.
- **Teto de RAM:** antes de cada `xcodebuild`, espere vaga —
  `while [ "$(pgrep -x xcodebuild | wc -l)" -ge 2 ]; do sleep 20; done`. Use timeout de 600000 ms.
- Cada task usa **só o simulador indicado**: dois `xcodebuild` no mesmo device brigam.
- Suíte do app na base: **411 testes, 0 falhas**. Sua task só pode aumentar esse número.

## Vocabulário compartilhado (já commitado na base, NÃO reescreva)

Escrito à mão antes do disparo, justamente para as tasks não inventarem três nomes para a mesma
coisa e para os arquivos ficarem **disjuntos**:

- `app/CutuqueApp/TipoDeArquivo.swift` — `TipoDeArquivo.de(nome:)` → `.imagem`, `.video`, `.audio`,
  `.pdf`, `.markdown`, `.json`, `.texto(Linguagem?)`, `.outro`; e `LimitesDeArquivo.tetoDePreview`
  (50 MB), `.tetoDeRealce` (200 KiB).
- `app/CutuqueApp/RealceDeSintaxe.swift` — **assinatura + implementação neutra** (devolve o texto sem
  cor). A Task R troca o corpo; quem chama já compila hoje.
- `FileViewerView` foi partido em três: a casca (`FileViewerView.swift`, carrega/edita/salva/roteia),
  `VisualizadorBinario.swift` (Task B) e `VisualizadorDeTexto.swift` (Task T). **Cada task mexe só no
  seu arquivo** — é o que fez a leva anterior mesclar sem um conflito.

---

## Task H — hub: download em fluxo e cauda do arquivo de texto

**Worktree:** `cutuque-worktrees/arquivos-hub` · **Sem simulador** (só `go test ./...`, rode em
`hub/`).

**Arquivos:**
- Modificar: `hub/internal/adapter/agent/target.go` (interface `DownloadFile`)
- Modificar: `hub/internal/adapter/claudecode/files.go` (Local e SSH; script de leitura)
- Modificar: `hub/internal/launcher/launcher.go:692`
- Modificar: `hub/internal/server/launch.go:38`, `hub/internal/server/machines.go:117-150`
- Modificar: `hub/internal/session/session.go:172` (campo `Tail`)
- Teste: `hub/internal/adapter/claudecode/files_test.go`, `hub/internal/server/machines_test.go`

> A parte 1 é troca de assinatura: **não dá para partir em tasks menores** sem deixar a árvore sem
> compilar entre elas. É exceção consciente à regra dos 3 arquivos, e o motivo está aqui escrito.

### Parte 1 — parar de bufferizar

Hoje `DownloadFile` devolve `[]byte` e o handler faz `w.Write(data)`: o arquivo inteiro passa pela
memória do hub. Troque por um `io.ReadCloser`:

- `DownloadFile(ctx, path) (io.ReadCloser, error)` na interface `Target` e em `Launcher`/`Launcher`
  do server.
- Nos dois alvos, use `cmd.StdoutPipe()` + `cmd.Start()`, e devolva um `io.ReadCloser` que no
  `Close()` fecha o pipe **e** faz `cmd.Wait()` — sem o `Wait` o processo vira zumbi a cada download.
- No handler, `io.Copy(w, rc)` com `defer rc.Close()`. Mantenha `Content-Disposition` e o
  `Content-Type` como estão.
- **Cuidado com o erro tardio:** com fluxo, o cabeçalho 200 já foi enviado quando o `cat` falha no
  meio. Não tente trocar o status depois; encerre a resposta. Escreva o comentário explicando isso.

**Testes:** que o `ReadCloser` devolve os bytes; que `Close` não deixa processo pendurado; que
`machine` desconhecida ainda dá 404 **antes** de qualquer byte; que caminho vazio dá 400.

### Parte 2 — cauda no `fs/read`

Em `readScriptFmt`, quando o arquivo **não é binário** e `size > maxReadBytes`, em vez de
`truncated=True` com conteúdo vazio: `seek` para `size - 204800`, ler até o fim, decodificar com
`'replace'`, **descartar tudo antes da primeira quebra de linha** (o corte cai no meio de um
caractere multibyte), e devolver `truncated=True` **e `tail=True`**.

- `session.FileContent` ganha `Tail bool \`json:"tail"\``.
- Binário continua igual: conteúdo vazio, sem cauda.
- Arquivo **menor** que 200 KiB nunca entra nesse caminho (já cabe inteiro).

**Testes:** parse de JSON com e sem `tail`; que `tail` só aparece com texto grande; que a primeira
linha parcial foi descartada; que binário não vira cauda.

**Commit:** `feat(hub): download em fluxo e cauda de arquivo de texto grande`.

---

## Task B — binários: QuickLook, teto e estados

**Worktree:** `cutuque-worktrees/arquivos-bin` · **Simulador:** `BAFE0F61-E116-4965-9B9A-D6E0AC461F04`

**Arquivos:**
- Modificar: `app/CutuqueApp/VisualizadorBinario.swift` (só este)
- Teste: `app/CutuqueAppTests/PreviewDeArquivoTests.swift` (novo)

**Consome:** `TipoDeArquivo.de(nome:)`, `LimitesDeArquivo.tetoDePreview`,
`APIClient.downloadFile(machine:path:)` (já grava no tmp com o nome original — é o que faz o
QuickLook escolher o renderizador certo), `FileEntry.size` e `.sizeLabel`.

**Comportamento:**
1. `entry.size <= tetoDePreview` → baixa ao aparecer e mostra o preview.
2. Acima do teto → **não baixa nada**; mostra tamanho e o botão "Baixar assim mesmo (1,2 GB)". O
   tamanho vem da listagem, então essa decisão não custa byte nenhum.
3. Enquanto baixa: progresso e possibilidade de sair da tela sem travar.
4. Falha → mensagem + "Tentar de novo", e o `ShareLink` de hoje continua disponível.

**QuickLook:** `QLPreviewController` via `UIViewControllerRepresentable`. Ele exige **URL de arquivo
em disco** — que é exatamente o que `downloadFile` devolve.

**A armadilha do iPad (decisão #19):** aba montada fica montada para sempre e `.onDisappear` **nunca
dispara** lá dentro. Sem tratar, trocar de aba deixa o **vídeo tocando**. `VisualizadorBinario`
recebe `isActive: Bool` e **desmonta o preview** quando ele é `false`. Não use `.onDisappear` para
isso: ele não vai chegar.

**Higiene:** o arquivo temporário é apagado quando a view sai — não deixe o tmp do iPhone encher com
vídeo de 40 MB a cada abertura.

**Testes** (o que dá sem simulador de UI): que o teto decide certo nas bordas (49,9 MB / 50 MB /
50,1 MB); que `TipoDeArquivo` roteia `.mov`, `.png`, `.pdf`, `.heic`, `.zip` para o QuickLook; que
nome sem extensão não quebra.

**Commit:** `feat(arquivos): preview de binario com QuickLook e teto de download`.

---

## Task R — o realçador de sintaxe

**Worktree:** `cutuque-worktrees/arquivos-texto-realce` · **Simulador:**
`C1165093-C583-47F2-A921-86A3B20BE810`

**Arquivos:**
- Modificar: `app/CutuqueApp/RealceDeSintaxe.swift` (só este — a assinatura já está lá, troque o
  corpo)
- Teste: `app/CutuqueAppTests/RealceDeSintaxeTests.swift` (novo)

**Produz:** `RealceDeSintaxe.aplicar(_ texto: String, linguagem: Linguagem?) -> AttributedString` —
**mantenha a assinatura**, a Task T já chama.

**Desenho:** um tokenizador varrendo o texto UMA vez, com a linguagem entrando como **dado**
(palavras-chave, marcador de comentário de linha, par de comentário de bloco, aspas válidas). Cubra:
comentário de linha, comentário de bloco, texto entre aspas com escape `\`, número, palavra-chave,
tipo (identificador começando com maiúscula). Linguagens: `swift go typescript javascript python
ruby rust java kotlin c cpp shell yaml toml sql html css json markdown`.

Markdown é ruleset próprio: título, **negrito**/_itálico_, `código`, cerca de código, link, item de
lista, citação.

**Não use** regex por token num laço sobre o texto inteiro — 200 KiB com 20 regex vira segundos.
Varredura de índice, uma passada.

**Regras duras:**
- **Nunca perder caractere.** A concatenação dos trechos coloridos tem de ser **idêntica** à entrada.
  É a asserção mais importante do arquivo de teste — cor errada incomoda, texto sumido é defeito.
- Acima de `LimitesDeArquivo.tetoDeRealce` (200 KiB) devolva sem cor, rápido, sem varrer.
- Cores por `Color` semântica que funcione em claro **e** escuro (o app tem os dois).

**Testes:** identidade do texto (acima); comentário no fim do arquivo sem quebra de linha; string não
fechada até o fim; `//` **dentro** de string não vira comentário; número colado em identificador;
arquivo vazio; texto acima do teto sai sem cor; markdown com cerca de código não colore o miolo como
prosa.

**Commit:** `feat(arquivos): realce de sintaxe proprio, sem dependencia nova`.

---

## Task T — o visualizador de texto: markdown, JSON, cauda e realce

**Worktree:** `cutuque-worktrees/arquivos-texto` · **Simulador:**
`0CC564B6-5D51-43DE-A603-F933197BF779`

**Arquivos:**
- Modificar: `app/CutuqueApp/VisualizadorDeTexto.swift` (só este)
- Modificar: `app/CutuqueApp/Models.swift` (campo `tail` em `FileContent`)
- Teste: `app/CutuqueAppTests/VisualizadorDeTextoTests.swift` (novo)

**Consome:** `TipoDeArquivo`, `RealceDeSintaxe.aplicar(_:linguagem:)` (hoje devolve sem cor — a Task R
troca o corpo; **não reimplemente**), `MarkdownText` (do chat, já com botão de copiar no bloco de
código).

**Comportamento:**
1. `.markdown` → `MarkdownText` renderizado por padrão; alternador "ver fonte" mostra o original
   passado pelo realçador. A preferência **não** persiste entre arquivos nesta leva.
2. `.json` → indentado antes de realçar. JSON inválido **não** é erro de tela: mostra o texto cru
   como veio (arquivo em edição é caso normal). Isole a indentação numa função pura e teste-a.
3. Demais textos → realce quando houver linguagem; monoespaçado quando não houver.
4. `content.tail == true` → faixa no topo dizendo que é **o fim do arquivo**, com o tamanho total e o
   botão de baixar o inteiro. `FileContent.tail` é **`Bool?`** — o hub de produção ainda não manda o
   campo, e `Bool` não-opcional com chave ausente **derruba o decode do arquivo inteiro**.
5. **Um único `Text`** com o `AttributedString`, `.textSelection(.enabled)` mantido. Não quebre em um
   `Text` por linha: mataria a seleção, que é exatamente o bug que a leva anterior consertou.
6. A edição (`TextEditor`) continua funcionando como hoje, sem realce — editar texto colorido é outro
   projeto. Com cauda, **desabilite salvar**: salvar 200 KB por cima de um arquivo de 5 MB o
   truncaria. Esse é o pior defeito possível desta task; trate-o explicitamente.

**Testes:** indentação de JSON válido e o passa-adiante do inválido; decode de `FileContent` **sem** a
chave `tail` (não pode lançar); decode com `tail: true`; a regra "com cauda não salva"; roteamento
`.md`/`.json`/`.ts`/`.log` para o modo certo.

**Commit:** `feat(arquivos): markdown renderizado, json formatado, cauda e realce no visualizador`.

---

## Depois das quatro (orquestrador)

Mesclar na ordem H → R → B → T (R antes de T para o realce já chegar de verdade no visualizador),
rodar a suíte inteira no iPad `E90308CB-9E6B-43C1-9BB5-58F51402FEB2` e o `go test ./...` do hub,
consertar os achados dos revisores — e mandar revisar **também o commit do orquestrador**, que é o
único código da entrega sem segunda leitura.
