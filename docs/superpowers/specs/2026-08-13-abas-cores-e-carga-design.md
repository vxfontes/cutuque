# Abas de navegador, cor de destaque de verdade e carga das sessões ao vivo

Data: 13/08/2026 · origem: seis apontamentos da Vanessa depois de rodar a **2.6.0 / build 19** no iPad.
Spec anterior desta área: `2026-08-12-abas-ipad-design.md` (decisão #19, aba de passagem).

## Os seis apontamentos, nas palavras dela

1. _"quando eu abro uma aba de uma sessao, e vou abrir outra, ela substitui a anterior (a fechando),
   ao inves de funcionar como um navegador que vai abrindo uma ao lado da outra, so se fixar
   funciona."_
2. _"a cor da aba ta um cinza estranho, preciso que reveja no ipad essa questao de configuração de
   cores pq mesmo eu trocando a cor, alguns lugares fica com cor padrao. a aba deve ficar fundo
   branco (modo claro) ou fundo escuro (modo escuro), e ai o nome e o x fica highlight com a cor que
   escolhermos nas preferencias."_
3. _"a parte de maquinas e board tb ta sofrendo isso da aba e ambos não tem opção de deixar tela
   cheia."_
4. _"a parte de personalizar a maquina não deixa escolher as coisas do hub tipo icone, tema e tal."_
5. _"não ta aparecendo o terminal / info embaixo da aba em terminais live e tal."_
6. _"ta com uma zica de loading, na verdade sempre existiu essa zica, para carregar as sessoes ao
   vivo, sempre preciso puxar pra baixo pra dar o refresh e conseguir visualiza-las."_

Os seis têm quatro causas comuns, e é por isso que cabem numa leva só: o **modelo de aba** (1, 3
parcialmente), o **token de cor errado** (2), a **barra de navegação disputada por N painéis
montados** (3, 5) e a **busca sequencial das vivas** (6). O item 4 é o único isolado.

## Diagnóstico com evidência

### Item 1 — a aba substitui em vez de abrir ao lado

`OpenTabs.abrir` tem `estilo: EstiloDeAba = .passagem` como **padrão**, e a passagem é por definição
única:

```swift
// OpenTabs.swift:114-116
if estilo == .passagem, let i = abas.firstIndex(where: { $0.estilo == .passagem && !$0.fixa }) {
    abas.remove(at: i)
}
```

Todos os chamadores reais (`SessionListView.swift:849`, `RootSplitView.swift:191/200/207`) omitem o
parâmetro, então **tudo abre como passagem** e cada abertura mata a anterior. Fixar funciona porque
`!$0.fixa` exclui a fixa da remoção — ou seja, o único jeito de acumular abas hoje é fixar, exatamente
como ela descreveu.

Isso era decisão minha, de 12/08: "aba de passagem = preview do VS Code". Estava escrito no comentário
do próprio enum. **A decisão está revogada** — ela quer navegador.

### Item 2 — a cor que ela escolhe não pinta

Duas causas independentes, e a segunda é a que explica "alguns lugares fica com cor padrao":

**(a) A barra usa material do sistema, não cor.** `TabBar.swift:54` é `.background(.bar)` (o cinza
estranho) e a aba escolhida é `AnyShapeStyle(.selection)` — cinza de seleção do sistema. O rótulo é
`.foregroundStyle(escolhida ? .primary : .secondary)`: nunca vê a cor de destaque.

**(b) `Color.accentColor` NÃO lê o `.tint()` da raiz.** O app injeta a escolha dela em
`CutuqueApp.swift:51` (`.tint((AppAccent(rawValue: accentRaw) ?? .blue).color)`), mas existem **24 usos
de `Color.accentColor`** espalhados (BoardView, QuestionCardView, SessionDetailView,
TerminalMirrorView, TerminalThemePicker, MachineInfoSheet, NewMachineView). `Color.accentColor` é uma
cor **resolvida do catálogo de assets / do sistema**, não o valor de ambiente do `.tint` — e o catálogo
deste app **não tem `AccentColor.colorset`** (só `AppIcon.appiconset`). Logo esses 24 pontos resolvem
para o azul do sistema e ignoram a preferência. Não é bug de propagação: é o token errado.

Há ainda azuis literais fora do sistema de cor: `FolderPickerView.swift:48`,
`NewSessionView.swift:219/228`, `MachineListView.swift:131`, `HistoryView.swift:173`,
`Models.swift:46` (`.running`), `SessionListView.swift:1131`.

### Itens 3 e 5 — a mesma causa estrutural

Pela decisão #19 a split view do iPad é montada uma vez e **os painéis das abas ficam montados para
sempre**, alternando por opacidade (`RootSplitView.swift:379-390`). Consequência que só apareceu agora:
os N painéis montados contribuem itens para a **MESMA** navigation bar. `SessionDetailPane.swift:153-161`
publica o seletor como `ToolbarItem(placement: .principal)` e o ⤡ como `.topBarTrailing`; com várias
abas abertas, N painéis disputam o mesmo `.principal` e o SwiftUI resolve isso escondendo — daí
"não ta aparecendo o terminal / info". `MachineDetailView.swift:101-104` faz igual com o seletor
terminal/arquivos, e o Board (`BoardView(embedded: true)`) não publica ⤡ nenhum: nunca teve tela cheia.

O ⤡ existe e funciona (`NavigationState.toggleColumns()`, ⌘⌃F) — só está preso à toolbar de um tipo de
painel.

### Item 4 — aparência da máquina inalcançável

`MachineInfoSheet.swift` **já tem** o `TerminalThemePicker` (:151) e a grade de ícones (:125-129), e
escreve por `EscritorDeAparencia` → `setAppearance(name:theme:icon:)` (:48). O formulário
(`NewMachineView`) tem `secaoTema` — mas **só ao cadastrar**: `:133` é literalmente
`if !modo.editando { secaoTema }`, e o comentário de `:129-132` explica por quê (o `PATCH` desta tela
manda `theme: ""`, que significa "mantém", e portanto não sabe expressar "volta ao padrão"; aparência é
do `PUT /appearance`). Ícone não aparece em lugar nenhum do formulário, nem ao cadastrar.

Resultado prático: editar máquina é justamente o lugar onde ela foi procurar, e é o único onde não
tem. O caminho que funciona (a sheet) fica atrás do botão de info de `MachineDetailView.swift:166-172`
— e o item 3 é parte da explicação de por que ela não chegou lá: com N painéis montados disputando a
toolbar, esse botão é um dos que o SwiftUI esconde.

### Item 6 — 11,3 segundos, medidos

`refreshLive()` (`SessionListView.swift:182`) busca **máquina por máquina, sequencialmente**, e só
publica `liveSessions` **no fim do laço**. Medido contra o hub de produção agora:

```
/targets ............ 0,0006 s → ["macbook","macmini","windows"]
macbook ............. 1,026 s (7 panes)
macmini ............. 0,239 s (0 panes)
windows ............. 10,016 s (0 panes)   ← ssh ConnectTimeout=10
SOMA SEQUENCIAL ..... 11,28 s
```

Os 10,016 s do `windows` são o `ConnectTimeout=10` do ssh do hub
(`internal/adapter/claudecode/target.go:290`) numa máquina que está desligada. As 7 panes do macbook
chegam em 1 s e **esperam o windows** para aparecer. Somando: a lista ao vivo leva 11 s para pintar,
**sem nenhum estado de carregando** — indistinguível de "não tem nada rodando". O `.refreshable`
(`:618`) parece resolver só porque ele mostra um spinner: o tempo é o mesmo, mas com spinner a espera
tem explicação. Piora: `.task` (`:622`) faz `await model.refresh()` **antes** de `startLivePolling()`,
então a soma de 11 s começa depois da carga do registro.

## As quatro decisões dela

1. **Fixar mantém o comportamento atual.** Segue protegendo de "Fechar outras/todas" e impedindo a aba
   de dormir no teto de 6 (`OpenTabs.maxVivas`). Deixa de ser a gambiarra contra a substituição.
2. **Cor: barra + varredura completa.** Arrumar a barra E varrer o app trocando cor fixa por cor de
   preferência, **preservando as semânticas** (vermelho destrutivo, verde ok, laranja aviso).
3. **Aparência da máquina nos dois lugares:** no formulário de editar E na sheet de informações.
4. **Uma barra de chrome para todas as abas:** uma faixa embaixo das abas com o seletor de painel e o
   ⤡, em qualquer tipo de aba. O seletor terminal/arquivos da máquina **migra** para ela em vez de
   empilhar uma segunda faixa.

## Desenho

### Modelo de navegador (item 1)

`EstiloDeAba` é **removido**, não desligado: passagem era o único motivo do enum existir, e enum morto
vira armadilha para a próxima pessoa. `abrir(chave:titulo:conteudo:)` perde o parâmetro `estilo`, o
bloco de remoção sai, e `AbaAberta.estilo` sai da struct. O itálico da passagem sai de
`TabBar.swift:79`.

O teto de 6 **não muda de papel**: com abas acumulando, mais abas dormem — e é exatamente para isso que
`vivas` (MRU) existe. Fixa continua garantindo vaga entre as vivas.

### Cor de destaque com um token que funciona (item 2)

Criar um valor de ambiente próprio, injetado ao lado do `.tint` na raiz:

```swift
// AppTheme.swift
private struct CorDeDestaqueKey: EnvironmentKey {
    static let defaultValue = AppAccent.blue.color
}
extension EnvironmentValues {
    /// A cor escolhida em Preferências, como Color de verdade.
    /// `Color.accentColor` NÃO serve: ele resolve do catálogo de assets (que aqui
    /// nem tem AccentColor) e ignora o `.tint()` da raiz — foi a causa de
    /// "mesmo eu trocando a cor, alguns lugares fica com cor padrao" (13/08/2026).
    var corDeDestaque: Color { get { self[CorDeDestaqueKey.self] } set { self[CorDeDestaqueKey.self] = newValue } }
}
```

Raiz: `.tint(cor).environment(\.corDeDestaque, cor)`. O `.tint` continua existindo porque é ele que
pinta controles nativos (Toggle, Picker, Button); o valor de ambiente serve para quem precisa da cor
como **valor** (`.opacity`, `.gradient`, parâmetro `Color`).

**Regra da varredura**, para não repintar o que é semântico:

| Papel | Vira cor de destaque? |
|---|---|
| Ação primária, seleção, destaque de identidade (`Color.accentColor`) | **sim** |
| Vermelho de destruir/parar/matar | não |
| Verde de sucesso/aprovar | não |
| Laranja/amarelo de aviso, `needs_you` | não |
| Cores de realce de sintaxe (`RealceDeSintaxe.swift`) | não — é paleta de linguagem |
| `.white` sobre fundo colorido (spinner em botão cheio) | não — é contraste |
| Estado `.running` de sessão (`Models.swift:46`) | **sim** — `SessionListView.swift:923` já faz isso; a varredura só torna consistente |
| Papel "user" no histórico de chat (`HistoryView.swift:173`) | **sim** — é identidade dela na conversa |

Verificação objetiva no fim: `grep -rn "Color.accentColor" app/CutuqueApp | wc -l` deve dar **0**.

### A barra de abas (item 2)

Comportamento de navegador, como ela descreveu:

- **Faixa** (fundo da barra): `Color(.secondarySystemBackground)` — superfície recuada, sem material.
- **Aba escolhida:** `Color(.systemBackground)` (branco no claro, quase-preto no escuro), com o
  título e o ✕ em `corDeDestaque`. É o "highlight" que ela pediu, e é o mesmo truque do Safari: a aba
  ativa é a folha da frente.
- **Abas não escolhidas:** fundo transparente, rótulo `.secondary`.

### Uma barra de chrome para todas as abas (itens 3 e 5)

O problema é disputa de toolbar; a solução é **sair da toolbar**. Uma view `ChromeDaAba` desenhada
**uma vez** por `abasDetail`, logo abaixo da `TabBar`, para a aba selecionada:

```
┌───────────────────────────────────────────────┐
│ [ mike ✕ ][ Board ✕ ][ macmini ✕ ]            │  TabBar
├───────────────────────────────────────────────┤
│   ( Chat | Terminal | Info )              ⤡   │  ChromeDaAba
├───────────────────────────────────────────────┤
│                                               │  painel
```

Como o pai sabe o que mostrar, com N painéis montados: um **registro de dados puros** em
`NavigationState`, escrito pelo painel e lido pela chrome — sem PreferenceKey (que combina os N
montados) e sem closure guardada em `ObservableObject`:

```swift
struct SegmentoDeChrome: Identifiable, Equatable, Hashable {
    let id: String        // "chat" | "terminal" | "info" | "arquivos"
    let titulo: String
    let simbolo: String
}

// NavigationState
@Published private(set) var segmentosDeChrome: [ChaveDeAba: [SegmentoDeChrome]] = [:]
@Published private(set) var escolhaDeChrome: [ChaveDeAba: String] = [:]
func definirSegmentos(_ s: [SegmentoDeChrome], de chave: ChaveDeAba)
func escolher(_ id: String, de chave: ChaveDeAba)
func limparChrome(de chave: ChaveDeAba)      // chamado ao fechar a aba
```

Fluxo em uma direção só: o painel **declara** seus segmentos e a escolha inicial (que vem da
persistência dele); a chrome **escreve** a escolha ao toque; o painel observa `escolhaDeChrome` e
aplica na própria persistência (sessão → `nav.definirPaneMode`; máquina → seu `@AppStorage`). Cada
painel continua dono do que persiste — nada de mudar onde a máquina guarda o painel dela.

O ⤡ fica na chrome, **sempre**, para qualquer tipo de aba (é o item 3: board e máquina passam a ter
tela cheia de graça). Atalho ⌘⌃F continua.

Segmentos vazios (Board, arquivado) → a faixa mostra só o ⤡. Uma faixa de ~34 pt constante vale mais
que uma que aparece e desaparece: a posição do ⤡ não muda ao trocar de aba.

### Aparência da máquina nos dois lugares (item 4)

- `MachineInfoSheet` já resolve; garantir que se **alcança** — o botão de info entra na chrome
  (`.topBarTrailing` da máquina disputava toolbar como todo o resto).
- A grade de ícones sai de dentro da sheet para um componente próprio
  (`SeletorDeIconeDeMaquina.swift`), porque agora tem dois consumidores. Ela já sabe o caso
  "Automático" (`id: ""` com o ícone do SO detectado) — duplicar isso à mão no formulário seria a
  forma mais fácil de as duas telas divergirem.
- `NewMachineView`, **no modo editar**, ganha ícone e tema chamando o **mesmo** `PUT /appearance`
  (`setAppearance`), não o `PATCH`. Isso preserva a razão original inteira: o `PATCH` continua
  mandando `theme: ""` (= mantém) porque continua não sabendo dizer "volta ao padrão" — o que muda é
  que a tela passa a chamar **também** o endpoint que sabe. Os comentários de `:129-132` e `:493-494`
  são **reescritos** com a razão nova e a data (13/08/2026), não apagados.
- Ao **cadastrar**, nada muda: segue só o tema, pelo caminho do POST. Máquina que ainda não existe não
  tem `PUT /appearance` para chamar — e é exatamente essa a assimetria que o comentário antigo
  registrava.

### Carga das sessões ao vivo (item 6)

Quatro mudanças, cada uma matando um pedaço dos 11 s:

1. **Paralelo:** `withTaskGroup` por máquina em vez do laço sequencial. Teto = `max(1,0,239, 10,016)`.
2. **Publicação incremental:** cada máquina que responde funde suas panes em `liveSessions` na hora.
   As 7 do macbook aparecem em ~1 s. O windows chega em 10 s trazendo zero — e ninguém sente.
   A regra atual de "limpa só após 2 leituras vazias seguidas" passa a ser **por máquina**, senão o
   windows (0 panes) apagaria o macbook.
3. **Não enfileirar:** `.task` inicia o polling ao vivo **antes** do `await refresh()`.
4. **Estado de carregando:** enquanto houver máquina pendente na primeira passada, a seção "Ao vivo"
   mostra uma linha com `ProgressView` + "procurando sessões…". Vazio silencioso é o que fazia ela
   puxar pra baixo.

A fusão vira um tipo puro (`MergedorDeVivas`) para ter teste de verdade: fundir por máquina, contador
de vazios por máquina, e a garantia de que máquina lenta não apaga máquina rápida.

**Fora do escopo, com recomendação:** o `ConnectTimeout=10` do hub é razoável para *abrir* sessão e
exagerado para *listar* (chamada de 15 em 15 segundos). Um timeout curto (3 s) só no caminho de
listagem (`internal/adapter/claudecode/tmux.go:138`) tiraria os 10 s na origem. Custa um deploy do hub
— fica como card próprio, decisão dela.

## Testes

Onde há lógica pura, teste de unidade (o app não tem UI test, é decisão do spec original):

- `OpenTabs`: abrir duas sessões seguidas mantém **duas** abas (o teste que hoje afirma o contrário é
  reescrito, não deletado — ele documenta a decisão revogada); fixar segue protegendo de "fechar
  outras"; teto de 6 segue dormindo por MRU.
- `NavigationState` chrome: registrar/ler segmentos por aba, escolher, limpar ao fechar, e que a
  escolha de uma aba não vaza para outra.
- `SessionDetailPaneLogic`: os segmentos passam a sair como `[SegmentoDeChrome]` com os ids fixos.
- `MergedorDeVivas`: fusão por máquina, máquina vazia não apaga a outra, 2 vazios seguidos limpam só
  aquela máquina.
- `AppAccent`: `corDeDestaque` resolve a escolha (e o default é azul).

Verificação que não é teste de unidade: `grep -c "Color.accentColor"` → 0, e a conferência no iPad
dela (é o único lugar onde "aparece o seletor" e "a cor pintou" se provam).

## O que esta leva NÃO faz

- Não mexe em como a máquina persiste o painel escolhido (`@AppStorage` por máquina fica).
- Não mexe em realce de sintaxe nem em cor de status semântica.
- Não muda o teto de 6 vivas nem a regra de dormir.
- Não toca no hub (o `ConnectTimeout` de listagem vira card separado).
- Não mexe em iPhone: a barra de abas e a chrome são do iPad (a split view). O iPhone segue em pilha.
