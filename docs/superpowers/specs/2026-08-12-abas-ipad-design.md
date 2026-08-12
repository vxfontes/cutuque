# Abas no iPad, novo terminal tmux e estado por agente — design

_2026-08-12 · autora: Vanessa (decisões) + /cutuque (redação e apuração)_
_Cards do board: `3452a97a553d1b9b` (abas) · `1a9b0169bf706dc2` (restoreSize) · `00ec95f3d8707a14` (novo terminal)_

## Objetivo

Fazer o app de iPad **navegar como PC**: abrir abas com sessões ao vivo, chats, o
Board e máquinas, trocando entre elas sem perder o que estava aberto.

Pedido literal da Vanessa: _"queria que o app de ipad seja um pouco mais de pc,
sabe? de forma que dê pra abrir abas com as sessões ao vivo e até o board e tudo
mais, facilitando a navegação no app"_.

Três frentes entraram junto porque compartilham o mesmo código e a mesma sessão de
desenho:

1. **Abas** — o pedido principal.
2. **`restoreSize()` no `✕`** — bug apurado: no iPad, fechar o terminal ao vivo
   **não** devolve a largura do pane ao tmux. Independente das abas, mas a troca de
   aba cria mais um caminho pelo qual o mesmo defeito apareceria.
3. **Botão de novo terminal tmux** com escolha de grupo, sessão, pasta e agente —
   e, junto dele, **estado do pane para codex e opencode**, que hoje não existe.

## Ponto de partida (verificado no código em 2026-08-12)

### O que já está pronto e sustenta as abas

O `SessionDetailPane` **já** é o modelo do que as abas precisam: mantém N painéis
montados num `ZStack` e alterna por **opacidade**, nunca por montagem condicional,
com `isActive` silenciando os de trás (`SessionDetailPane.swift:86`):

```swift
TerminalMirrorView(machine: …, target: …, title: …,
                   isActive: showsTerminal, ownsNavigationTitle: false)
    .opacity(…) .allowsHitTesting(…) .accessibilityHidden(…)
```

Isso é a **decisão #19** do projeto: uma raiz de split view só, construída uma
vez, nunca substituída. As abas herdam a regra — nada de estrutura muda, só estado.

O `✕` cinza não desmonta nada, só troca modo (`SessionDetailPane.swift:164`):

```swift
Button { nav.paneMode = .info } label: { Image(systemName: "xmark") }
```

E o comentário da linha 97 preserva a instrução da Vanessa palavra por palavra:
_"nao é pra kill, é apenas pra fechar o terminal mas ele deve continuar
trabalhando na sessao tmux"_.

### O que bloqueia as abas hoje

Existe **um** painel de detalhe por vez, destruído por `.id(selection)`
(`RootSplitView.swift:247`) e `.id(machine.name)`. O comentário ali diz que é
_"aí, e só aí, que o `restoreSize()` do terminal deve rodar"_ — hoje é o único
ponto de destruição, e é justamente o que as abas têm de substituir.

### O bug do `✕` (frente 2)

`restoreSize()` existe **só** no `onDisappear` (`TerminalMirrorView.swift:305`):

```swift
.onDisappear { resizeDebouncer.cancel(); model.stop(); model.restoreSize() }
```

No **iPhone** o terminal é um `NavigationLink` empurrado
(`TerminalMirrorView.swift:585`), então voltar sempre dispara `onDisappear`. No
**iPad** a view fica montada para sempre e o `✕` só troca `paneMode` — o
`onDisappear` nunca roda e o pane segue em `window-size manual`, preso na grade do
iPad. **Não é intermitente: é determinístico.** Só voltava ao normal por efeito
colateral de sair da sessão.

O mecanismo do lado do hub está correto (`tmux.go:255`): `cols/rows > 0` aplica
`window-size manual` + `resize-window`; `cols == 0` volta para `window-size
latest`. O comando simplesmente não é chamado.

Armadilha do conserto: `.task(id: resizeKey)` (`TerminalMirrorView.swift:262`) não
reentra quando só `isActive` muda, porque `resizeKey` é
`"\(grid.cols)x\(grid.rows)"` (`:236`) e não contém `isActive`.

### O novo terminal (frente 3) — quase tudo existe

O `tmuxListScript` (`tmux.go:20`) já varre **todos** os servidores `-L`; o
comentário diz explicitamente que é _"pois o `tmx.sh` da usuária agrupa por
servidor"_.

E o hub **não** joga fora o que a lista agrupada precisa
(`tmux.go:382`):

```go
func TmuxPaneAsDiscovered(p TmuxPane) session.Discovered {
    // title = p.Session, caindo para o basename do Cwd se vazio/numérico
    return session.Discovered{ID: p.ID, Cwd: p.Cwd, Title: title, State: p.State, Agent: p.Cmd}
}
```

- `ID` é `"<socket>\t<pane>"` → **o grupo viaja dentro do ID**;
- `Title` é o **nome da sessão** do tmux;
- `Cwd` é a **pasta**;
- `Agent` é o agente detectado.

A máquina não está no `Discovered` e **não precisa estar**: o app sabe para qual
máquina pediu, que é o `LiveEntry.machine` (`SessionListView.swift:8`).

**Conclusão: a lista agrupada não exige mudança no hub.** Sobram para o hub a
descoberta de shells e o endpoint de criar.

Os quatro comandos de criação já existem no `scripts/tmx.sh` da Vanessa:

| agente | comando | linha |
|---|---|---|
| claude | `new-session -A -s <s> -c <pasta> 'claude'` | `:153` |
| codex | `… 'codex --sandbox danger-full-access'` | `:164` |
| opencode | `… 'opencode'` | `:175` |
| terminal vazio | `new-session -d -s <s>` (sem comando) | `:59` |

E o grupo é o socket: `SRV="${TMX_SRV:-main}"` / `TM() { tmux -L "$SRV" "$@"; }`
(`tmx.sh:23-24`). Não existe registro de grupo — `tmux -L <nome>` cria o servidor
na hora.

### O estado por agente (frente 3b) — calibrado com captura de tela real

Hoje o estado é inferido **só** para o Claude (`tmux.go:98`):

```python
st = pane_state(sock, f[0]) if ag == 'claude' else ''
```

O comentário ao lado declara o motivo: _"não arriscamos rotular um estado
errado"_. Consequência: sessão de codex/opencode chega no app sem bolinha.

Calibração feita em 12/08 dirigindo as TUIs de verdade e lendo `capture-pane`:

| agente | versão | tela alternativa | `running` | `waiting` |
|---|---|---|---|---|
| claude | 2.1.228 | — | `(Ns` + `esc to interrupt` + `agent(s) to finish` | `do you want to proceed` / `…make this edit` |
| codex | 0.147.0 | `alternate_on=0` | **`• Working (29s • esc to interrupt)`** | só o portão de confiança (abaixo) |
| opencode | 1.18.16 | `alternate_on=1` | **`esc interrupt`** + spinner de blocos | não existe |

Achados que mudam o desenho:

1. **O codex já é detectado pelas regras atuais, sem marcador novo.** A tela real
   de uma sessão trabalhando é `• Working (29s • esc to interrupt)` — casa no
   `work_re` (`(29s`) **e** no `esc to interrupt`. Timer vivo confirmado
   (29s → 31s → 33s em leituras de 2s). Tirar o portão `if ag == 'claude'` faz o
   codex funcionar de imediato.
2. **`esc interrupt` ≠ `esc to interrupt`.** O opencode escreve **sem** o "to", e a
   checagem atual não o pega. Trocar por um `in "interrupt"` genérico é frágil: o
   marcador tem de ser por agente.
3. **`waiting` de aprovação de ferramenta é inalcançável** na configuração da
   Vanessa. O `~/.config/opencode/opencode.json` tem
   `"permission": { "*": "allow", "bash": "allow", "edit": "allow", … }` — pedi para
   rodar `ls -la` pela ferramenta de bash e **rodou direto, sem diálogo**. O
   `tmx cx` roda `--sandbox danger-full-access`, mesma coisa. Encaixa com o que o
   código já dizia: `esc to interrupt` também não aparece no modo
   bypass-permissions do Claude.
4. **O opencode imprime a duração _depois_ de concluir**:
   `▣ Build · <modelo> · 3.2s`. Quem "melhorar" o `work_re` tirando a exigência do
   parêntese faz toda tela ociosa do opencode virar `running` para sempre. **O
   parêntese é o que segura o falso positivo** — precisa de comentário no código.
5. **O portão de confiança do codex, e este importa direto para a feature nova.**
   Sessão de codex criada numa pasta que ele ainda não conhece para em:

   ```
   Do you trust the contents of this directory? …
   › 1. Yes, continue
     2. No, quit
   ```

   As regras atuais classificam isso como **`idle`** — verde, "concluído" — quando
   a sessão está travada esperando uma tecla para sempre. O formulário de criação
   escolhe pasta arbitrária, então **isso vai acontecer**.

Evidência completa e método reprodutível em
`memory/cutuque/backend/Backend — Estado do Pane por Agente (claude, codex, opencode).md`.

### O custo real da lista agrupada por grupo

`liveByServer` (`SessionListView.swift:376`) agrupa por `machine + "\t" + socket`, e
o comentário logo acima (`:374`) explica por quê: _"agrupar só por ele juntaria
numa seção só panes de máquinas diferentes — com um 'encerrar server' que mataria a
errada."_

O cabeçalho da seção tem exatamente uma ação destrutiva
(`SessionListView.swift:414-420`):

```swift
serverToKill = ServerKill(machine: group.machine, socket: group.socket, name: group.label)
```

Se o grupo passa a misturar máquinas, `group.machine` deixa de ser único e essa
ação fica **ambígua** — e ambiguidade em ação destrutiva é inaceitável. É esse o
custo de D9, não só "aposentar duas funções".

### Estado das branches (risco de integração)

Duas branches em voo, **nenhuma mergeada, nenhuma pushada, hub não redeployado**:

- `identidade-pane-ao-vivo` — commits `f3aef96` + `933e9db`, card
  `2136ff6c8e12ed22` (Em revisão). É o que separa `LiveEntry.paneTarget` de
  `LiveEntry.id`, e **é o que torna grupo com mesmo nome em duas máquinas seguro**.
- `versao-ipad` — 132/132 testes, aceitação no iPad físico pendente.

O trabalho desta spec empilha em cima das duas.

## Decisões travadas

**D1 · Tocar numa sessão substitui a aba de passagem.** Modelo do VS Code: a aba é
"de passagem" até ser fixada. Se a sessão já está aberta em alguma aba, **foca** em
vez de duplicar.

**D2 · As abas voltam ao reabrir o app.** Com a ressalva: aba de sessão ao vivo que
não existe mais volta como **aviso**, nunca reabrindo pane no tmux por conta
própria.

**D3 · Teto de 6 abas vivas**, o resto dormindo (solta recursos, recarrega ao
voltar). A barra rola. Número escrito num lugar só. **Dormir = `liberado`**: a aba
que dorme para o polling **e devolve a largura** ao tmux, senão o pane fica preso na
grade do iPad enquanto ninguém está olhando.

**D4 · Barra lateral unificada**, duas colunas: destinos em cima, lista do destino
ativo embaixo. É ela que faz a proposta parecer PC de verdade e devolve largura ao
terminal no 11".

**D5 · A barra de abas mora dentro da coluna de conteúdo.** Não toca na raiz, então
risco estrutural zero. O `☰` e o `⤢` continuam existindo e funcionando — pergunta
explícita da Vanessa, respondida: com o `☰` as abas passam a ocupar a tela toda.

**D6 · Toque longo na aba abre menu:** Fixar / Fechar outras / Fechar todas.

**D7 · `restoreSize()` roda no `✕` e também quando o app vai para o background.**
Sair do app devolve o pane ao normal no PC.

**D8 · O terminal livre nasce sem agente nenhum** — só o shell.

**D9 · Um grupo, máquinas misturadas dentro, ícone por linha.** Grupo `defender`
reúne `mike` (macbook) e `mikeaux` (windows) numa seção só, cada linha com ícone da
máquina e a pasta. Grupo é **projeto/contexto**; máquina é detalhe de execução —
casa com o modelo do board. Aposenta `serversAmbiguos()` e `rotulo()`.

**D10 · O botão "codex" copia o `tmx cx`**, com `--sandbox danger-full-access`. App
e terminal dão a mesma coisa.

**D11 · Shell sem agente aparece na lista, marcado.** Sem isso o terminal criado
some no refresh seguinte e não há como voltar nele.

**D12 · Validação de nome de grupo e sessão no formulário do iPad/iPhone.**
`A-Z a-z 0-9 - _`, barrado no teclado — não num erro criptográfico depois. O socket
viaja como caminho validado por `^/[A-Za-z0-9._/ -]+$` (`tmux.go:107`) e o tmux usa
`:` e `.` como separador de alvo.

**D13 · Grupo novo é permitido e não tem cerimônia.** Digitar um nome que não existe
**é** criar o grupo. Consequência declarada: grupo é o mesmo identificador do
escopo do board (`CUTUQUE_GROUP` = socket), então grupo novo = escopo novo
aparecendo no board.

Decisões de redação, tomadas por mim e registradas para poderem ser contestadas:
máquina volta dormindo; nunca duas abas do mesmo alvo; Board e Arquivo nascem
fixos; fechar a última aba é permitido; ordem = ordem de abertura.

## Arquitetura

### Frente 1 — Abas

**`OpenTabs.swift` (novo).** O modelo, testável sem View:

- `Tab`: `id`, `kind` (`.live(machine, paneTarget)`, `.chat(sessionID)`, `.board`,
  `.machine(name)`, `.archive`), `isPinned`, `isTransient`.
- Regras puras: abrir (substitui a de passagem, foca se já existe, nunca duplica
  alvo), fechar, fixar, reordenar, e **quem dorme** quando passa de 6.
- Persistência das abas (D2) com reconciliação: aba de sessão morta volta como
  aviso.

**Estado de três valores, não dois.** Hoje `isActive` é booleano. Com abas ele
precisa distinguir:

| estado | polling | largura do tmux |
|---|---|---|
| `ativo` | roda | aplicada |
| `suspenso` (troquei de aba) | para | **mantida** |
| `liberado` (`✕` ou fechei a aba) | para | **devolvida** |

Sem o estado do meio, cada troca de aba viraria dois POSTs de resize.

**`RootSplitView`** ganha a barra de abas dentro da coluna de conteúdo e passa a
manter N painéis montados, alternando por opacidade — a mesma regra do
`SessionDetailPane`, subida um nível. O `.id(selection)` sai; quem decide destruir
passa a ser o `OpenTabs`.

**`NavigationState.expandedVisibility` fica mais simples.** Com a barra lateral
unificada (D4), a orientação sai da conta:

```swift
// hoje: .sessions/.machines devolvem lastIsPortrait ? .doubleColumn : .all
// depois: duas colunas sempre
```

**`LiveHub.swift` (novo).** N abas ao vivo hoje significam N WebSockets:
`SessionDetailView.startLiveUpdates` (`:56`) abre um `api.liveUpdates()` por view
model e filtra no cliente. O `LiveHub` centraliza uma conexão e distribui por alvo.
**É consequência das abas, não escolha:** com teto de 6, seriam 6 conexões.

### Frente 2 — `restoreSize()`

Um arquivo, `TerminalMirrorView.swift`:

1. `isActive` entra na chave do `.task`, senão ele não reentra:
   `resizeKey` passa a incluir o estado.
2. `restoreSize()` passa a ser chamado na transição para `liberado` — não só no
   `onDisappear`, que continua existindo para o caminho do iPhone.
3. `scenePhase` → background chama `restoreSize()` (D7).

O `onDisappear` **não sai**: é o caminho correto no iPhone e a rede de segurança no
iPad.

### Frente 3 — Novo terminal tmux

**Hub — criar.** `Tmuxer` (`tmux.go:124`) ganha:

```go
TmuxNewSession(ctx context.Context, socket, session, cwd, agent string) (target string, err error)
```

Monta o que o `tmx.sh` já monta:
`tmux -L <grupo> new-session -A -s <sessão> -c <pasta> [<comando do agente>]`.
O `-A` **anexa se já existir**, que é o comportamento certo de graça. Validação de
socket/sessão do lado do hub também (defesa em profundidade, D12 é a camada de UX).

Rota nova no `internal/server`, seguindo o padrão do `launch.go`, e
`Launcher.TmuxNewSession` resolvendo a máquina como o `TmuxList` faz
(`launcher.go:304`).

**Hub — descoberta de shells (D11).** O `tmuxListScript` filtra `if not ag:
continue` (`tmux.go:94`). Passa a **manter** o pane e marcá-lo. `TmuxPane` ganha
`Kind` (`"agent"` | `"shell"`), e `Discovered` ganha o campo correspondente para o
app diferenciar. Pane de shell **não** passa pelo `pane_state` — não há TUI para ler.

**App — formulário.** Cinco campos, cinco fontes que já existem: máquina
(`/targets`), grupo (sockets varridos, com nome novo permitido — D13), sessão
(texto), pasta (`ListDirs`, o mesmo da aba Arquivos), agente (os quatro do
`tmx.sh`).

**App — lista agrupada (D9).** `liveByServer` reagrupa por **nome do server**, não
por `machine + socket`. Cada linha ganha ícone da máquina (`laptopcomputer`,
`desktopcomputer`, `pc`) e a pasta. `serversAmbiguos()` e `rotulo()` saem, com os
testes deles.

**E a ação destrutiva do cabeçalho deixa de ser única:** "Encerrar server" passa a
ser **uma entrada por máquina presente no grupo** ("Encerrar server no macbook",
"Encerrar server no windows"). Isso resolve a ambiguidade que o comentário de
`:374` antecipou.

### Frente 3b — Estado por agente

**Tabela de marcadores por agente**, num lugar só, no lugar do `if ag == 'claude'`
fundido na função. Agente novo = linha nova. A tabela nasce com a evidência de 12/08:

| agente | `running` | `waiting` |
|---|---|---|
| claude | `work_re` · `esc to interrupt` · `agent(s) to finish` | `do you want to proceed` · `do you want to make this edit` |
| codex | `work_re` · `esc to interrupt` (**as regras do claude servem**) | `do you trust the contents of this directory` |
| opencode | `esc interrupt` (**sem** "to") | — (não existe) |

**O portão de confiança vira `waiting`, não `idle`** (achado 5). É o caso que a
feature nova cria: sessão travada num prompt de confiança reportada como concluída.

O comentário que hoje justifica o portão é **reescrito**, não apagado: passa a
registrar que a inferência foi calibrada por captura, com data, e que o parêntese
do `work_re` é defesa contra o falso positivo do opencode (achado 4).

**Deliberadamente fora:** o hash de tela entre polls, que eu havia proposto como
sinal agnóstico de TUI. Com `esc to interrupt` confirmado no codex e `esc
interrupt` no opencode, ele deixou de ter função e traria uma guarda nova (TUI que
anima parada daria "mudou" para sempre). YAGNI.

## Tratamento de erro

- **Criar sessão numa máquina inalcançável** → erro da rota, mensagem nomeando a
  máquina. Nada é criado pela metade: o `new-session -A` é atômico do ponto de vista
  do app.
- **Nome inválido** → barrado no campo (D12); se chegar ao hub, rejeitado pelos
  padrões de `tmux.go:107`.
- **Sessão já existente** → **não é erro**: o `-A` anexa e o app abre a aba nela.
- **Aba de sessão morta** (D2) → aviso na aba, sem recriar pane.
- **Pane de shell** → sem estado, sem tentativa de ler TUI.
- **Portão de confiança** → `waiting`, para a Vanessa ver que precisa responder.

## Testes

Seguindo o padrão do projeto — função pura fora da View, para testar sem simulador:

- `OpenTabs`: abrir/substituir/focar, nunca duplicar alvo, teto de 6 e quem dorme,
  fixar, fechar a última, reconciliação de aba morta.
- Estado de três valores: as transições que devolvem largura e as que não.
- `restoreSize()`: teste que **falha antes e passa depois** para o caminho do `✕` no
  iPad e para o background.
- `liveByServer` reagrupado: grupo de mesmo nome em duas máquinas cai numa seção só,
  com uma entrada de "Encerrar server" **por máquina**.
- Tabela de marcadores: uma asserção por linha da tabela, com **as telas reais
  capturadas em 12/08 como fixture** — inclusive a tela ociosa do opencode com
  `· 3.2s`, que é o caso que pega quem afrouxar o `work_re`.
- Portão de confiança do codex → `waiting`.

## Fases

Ordenadas por dependência e por valor entregue. Cada fase é pequena de propósito —
a regra da Vanessa é parar e quebrar quando passa de 3 arquivos.

| fase | o que | arquivos | depende de |
|---|---|---|---|
| **F0** | `restoreSize()` no `✕` e no background | `TerminalMirrorView.swift` + testes | — |
| **F1** | Estado por agente: tabela de marcadores, codex e opencode, portão de confiança | `tmux.go` + testes | — |
| **F2** | Descoberta de shells marcados | `tmux.go`, `session.go` + testes | F1 |
| **F3** | `TmuxNewSession` no hub + rota | `tmux.go`, `launcher.go`, rota + testes | F2 |
| **F4** | Formulário de criação no app | view nova + `CutuqueAPI` | F3 |
| **F5** | Lista agrupada por grupo, ícone por linha, kill por máquina | `SessionListView.swift` + testes | — |
| **F6** | `OpenTabs` + barra de abas + N painéis | `OpenTabs.swift`, `RootSplitView.swift`, `NavigationState.swift` + testes | F0 |
| **F7** | `LiveHub`: uma conexão para N abas | `LiveHub.swift`, `SessionDetailView.swift` | F6 |

**F0, F1 e F5 são independentes** e podem sair primeiro, em qualquer ordem. F6 é a
maior e é onde mora o risco estrutural; F7 só existe por causa dela.

## Fora de escopo

- Mexer no `scripts/tmx.sh` — é script da Vanessa, mudança dela, não minha.
- Fechar a semana do board (`close-week` é da mantenedora, roda automático).
- Abas no **iPhone**: a tela não tem largura para isso, e o `NavigationLink` de lá
  já funciona.
- Reordenar aba arrastando: ordem é ordem de abertura, e arrastar entra depois se
  ela sentir falta.
- Sincronizar abas entre iPad e iPhone.
- Detectar estado de agente que não seja claude/codex/opencode.

## Pendências a confirmar na implementação

1. **As duas branches não mergeadas.** `identidade-pane-ao-vivo` precisa entrar
   **antes** de F5: sem a separação `paneTarget`/`id`, grupo de mesmo nome em duas
   máquinas colide na lista — que é exatamente o caso que D9 torna comum. Decidir com
   a Vanessa se merge e deploy vêm antes de começar.
2. **Onde a barra de abas rola** no 11" com 6 abas abertas — medir no aparelho, não
   no papel.
3. **O teto de 6** é palpite calibrado, não medida. Revisar depois que ela usar.
4. **`opencode` em tela alternativa** (`alternate_on=1`): confirmar que o
   espelhamento e o resize se comportam igual ao codex/claude, que usam a tela
   normal. A captura funciona — o resto não foi exercitado.
5. **Marcadores versionados.** `codex 0.147.0` e `opencode 1.18.16` foram os
   calibrados. Atualização de TUI pode mudar string; a tabela precisa ser fácil de
   recalibrar, e o método está gravado na memória.
6. **Duas abas em panes da _mesma janela_ do tmux.** "Nunca duas abas do mesmo alvo"
   impede o mesmo pane, mas não dois panes irmãos. `window-size` é da **janela**,
   não do pane: duas abas suspensas na mesma janela disputariam a largura. Confirmar
   se acontece no uso dela; se acontecer, a largura passa a ser por janela, com a
   aba ativa ganhando.
7. **Um plano de implementação por fase**, não um plano só. Esta spec é o guarda-chuva
   das quatro frentes; F6 sozinha já é um plano inteiro. Decidir a ordem com a
   Vanessa antes de escrever o primeiro.
