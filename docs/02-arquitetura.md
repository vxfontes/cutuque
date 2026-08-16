# 02 — Arquitetura

> **Como ler este documento:** o corpo original de 2026-07-02 (único commit que este
> arquivo teve até então) fica abaixo intacto — segue sendo o desenho verdadeiro do
> núcleo do sistema, e nada foi apagado. Onde a realidade andou desde julho, a
> divergência leva uma nota inline "Revisado em 2026-08-16" bem ao lado do trecho
> afetado, em vez de reescrever o trecho por cima. O que é inteiramente novo — pacotes
> que não existiam ainda em julho — ganhou seções próprias no fim do arquivo, também
> datadas: "Componentes adicionados", "Métricas de forma" e "Bypasses conhecidos do
> contrato". Rodapé com a data da última revisão.

## Visão de alto nível

```
[iPhone / Apple Watch]  <—WebSocket/REST (Tailscale)—>  [Hub @ 192.0.2.10]
        ^                                                        |
        |                                          tailscale ssh | (native-first, tmux fallback)
        └────────— APNs (só metadados) —————┐                    v
                                            |         [MacBook]  [Windows/WSL2]  ...
                                     [Apple APNs]      Claude / Codex / OpenCode
```

## Decisões de arquitetura

### Hub cérebro + apps finos

Toda a inteligência (registro de sessões, detecção de estado, orquestração, APNs) mora no
hub. Os apps iOS/watchOS são viewers finos: mostram estado e enviam ações. Isso é crucial
para o watchOS (recursos limitados) e para publicar um app simples rapidamente.

### Controle native-first (Cano 2), tmux como fallback

O canal primário de controle é a **interface nativa** de cada agente, que dá eventos
precisos e estruturados em vez de "ler a tela":

| Agente | Interface nativa | Uso |
|--------|------------------|-----|
| Claude Code | headless/SDK (`claude -p --output-format stream-json`) + hooks (Stop, Notification, PreToolUse) | lançar, observar, detectar `done`/`needs_you`, aprovar |
| OpenCode | servidor HTTP embutido (`opencode serve`) + SDK | lançar, observar via API |
| Codex | `codex exec` + saída JSON | disparos one-shot |

O **tmux** permanece como:
- **fallback universal** — para qualquer agente/comando sem interface nativa boa;
- **escape hatch** — o usuário ainda pode `ssh` + attachar a sessão real quando quiser.

### O hub pode lançar sessões

Além de observar, o hub **inicia tarefas novas** nas máquinas-alvo pelas interfaces
nativas. O usuário dispara do celular sem abrir terminal.

### Transporte

- **WebSocket + REST** (hub ↔ app) sobre Tailscale: lista de sessões, stream de output ao
  vivo, envio de texto/ações, aprovação de prompts. Usado quando o app está aberto.
- **APNs** (hub → Apple → Watch/iPhone): notificações e haptics quando o app está em
  background/fechado.

## Componentes do hub

Cada componente tem uma responsabilidade única e um contrato claro. Isso mantém as partes
testáveis e substituíveis de forma isolada.

- **Session Registry** — fonte da verdade das sessões conhecidas: máquina + agente +
  identificador + estado atual. Os demais componentes leem/atualizam aqui.
- **Adapters nativos** (um por tipo de agente) — encapsulam como lançar/observar cada
  agente: Claude Code (headless/SDK + hooks), OpenCode (HTTP), Codex (exec). Rodam contra
  as máquinas-alvo via `tailscale ssh`. Emitem eventos normalizados para o State Engine.
- **tmux Collector** (fallback) — quando não há adapter nativo: `tmux capture-pane` para
  ler e `tmux send-keys` para escrever; detecção por heurística de texto.
  > **Revisado em 2026-08-16:** isso descrevia a intenção, não o que foi construído. Não
  > existe um componente `tmux Collector` próprio — `Tmuxer`/`TmuxPane` vivem dentro de
  > `hub/internal/adapter/claudecode` (`tmux.go`, `target.go`), como parte do adapter do
  > Claude Code, não como uma peça de responsabilidade única ao lado dos outros cinco
  > componentes desta lista. O pacote-base compartilhado entre adapters
  > (`internal/adapter/agent`, ver `handle.go:1-5`) não menciona tmux — a base é
  > `Handle`/`Runner`/`Target`, agnóstica de terminal. Na prática o fallback via tmux
  > ficou acoplado ao Claude Code em vez de virar um colecionador genérico para
  > "qualquer agente/comando sem interface nativa boa" como o parágrafo acima descreve.
- **State Engine** — consome eventos (nativos, precisos; ou tmux, heurísticos) e move cada
  sessão pela máquina de estados. Decide quando disparar notificação.
- **Notifier (APNs)** — nas transições relevantes, monta o push com o tipo de haptic e o
  metadado, e envia à Apple. Guarda a credencial `.p8`.
- **Command API (WebSocket + REST)** — a superfície que o app consome: listar sessões,
  assinar stream de output, enviar texto/teclas, lançar tarefa, aprovar/negar prompt.

## Contratos entre componentes

- **Adapter → State Engine:** eventos normalizados (`session_started`, `output_chunk`,
  `needs_input`, `permission_requested`, `finished`, `errored`), independentes do agente.
- **State Engine → Notifier:** transições relevantes (`→ needs_you`, `→ done`, `→ error`)
  com metadado mínimo.
- **Command API → Adapter:** comandos (`launch`, `send_text`, `approve`, `deny`).
- **Registry:** consultado/atualizado por todos; nunca escrito por dois componentes para o
  mesmo campo sem passar pelo State Engine.

Detalhe da máquina de estados em [03 — Modelo de estado](03-modelo-de-estado.md).

---

## Componentes adicionados (pós-07-02) — revisado 2026-08-16

Os seis componentes acima descrevem o núcleo com que o projeto saiu do brainstorming.
Três pacotes nasceram depois e não têm representação nenhuma no desenho original — quem
lê só até aqui entende metade do hub de hoje achando que entendeu o todo. Datas de
nascimento por `git log --diff-filter=A`.

### Board — quadro Kanban dos agentes (`internal/board`, nasceu 2026-07-13)

Fonte da verdade de `Task`: os cards do board que o CLI `cutuque` e o dashboard web
manipulam (coluna, grupo, sessão associada, tipo de agente, role, comentários, flag de
"encalhada"). Deliberadamente **não importa** `session`/`registry`/`engine` — é um
domínio adjacente ao ciclo de vida de sessão, não acoplado a ele. Duas implementações da
interface `Store`: `MemStore` (memória + JSON opcional em disco, usado em dev/testes) e
`PostgresStore` (schema `cutuque` no Postgres, com fechamento automático toda semana —
`StartWeeklyCloser` dispara `CloseWeek` todo domingo 23:59 em `America/Sao_Paulo` —
mais arquivamento). Quem fala com ele: `cmd/hub/main.go` escolhe o `Store` na
inicialização (Postgres se `CUTUQUE_DATABASE_URL` estiver setada, migrando um
`board.json` pré-existente na primeira vez se o banco chegar vazio; senão `MemStore`
com persistência em arquivo, se `CUTUQUE_SESSIONS_PATH` estiver setada — sem nenhuma
das duas, board fica só em memória);
`internal/server` expõe as rotas HTTP do quadro (ver "Métricas de forma" abaixo);
`internal/server/ws.go` propaga toda mudança (`board_snapshot` ao conectar,
`board_updated`/remoção depois) pro dashboard ao vivo. Documentação própria em
[`board-protocol.md`](board-protocol.md) — o único dos três pacotes novos com doc
dedicado, e ele próprio não está desatualizado (já cobre `search`, `mentions`,
`close-week`, os comandos mais recentes do CLI).

### Reaper — sessões zumbi (`internal/reaper`, nasceu 2026-07-27)

Resolve um buraco que o desenho original não previa: uma sessão que entra em `running` e
nunca recebe evento de saída (processo morto sem `Stop`, terminal fechado, `claude` novo
reaproveitando o mesmo pane) ficava `running` para sempre — nada reavaliava estado com o
tempo. Postura deliberadamente conservadora: na dúvida (ssh caiu, oráculo respondeu com
erro) o reaper **não age**, porque o custo de um zumbi a mais é muito menor que apagar
da lista uma sessão que ainda está viva. Varre o `Registry` periodicamente — intervalo
default de 5 minutos, período de graça de 30 minutos antes de considerar morta (constantes
`defaultInterval`/`defaultGrace` em `reaper.go`, ajustáveis via `SetInterval`/`SetGrace`
antes de `Start`) — e, ao confirmar morte, aciona o **Engine** (nunca escreve direto no
Registry: `reaper.go` importa `engine`, `registry` e `session`, condizente com o contrato
"só o Engine escreve estado"). Não persiste nada por conta própria; só lê e decide.
Único ponto de wiring: `cmd/hub/main.go:209`, `reaper.New(eng, reg, lch, logger)`, rodando
como goroutine de fundo. Sem doc próprio.

> **[16/08/2026] Correção:** a frase acima ("aciona o Engine, nunca escreve direto no
> Registry") só vale para o caminho **Idle** de `resolve()` — `rp.eng.Idle(...)`, que
> passa pelo Engine de verdade. Existe um SEGUNDO caminho em `resolve()`, **Forget**
> (quando o transcript já não existe mais no disco, `reaper.go:233`): `rp.reg.Forget(id,
> StateRunning)` apaga a sessão direto do Registry (`delete(r.byID, id)`); só DEPOIS vem
> `rp.eng.RecordForgotten(id)` (`reaper.go:234`), que alimenta só o histórico do Postgres
> — não decide estado nenhum, o estado (sumir do Registry) já foi decidido antes, fora
> do Engine. É bypass do contrato "só o Engine escreve estado", mesma categoria dos
> outros documentados na seção "Bypasses conhecidos do contrato" abaixo (linha nova na
> tabela).

### Machine — registro de máquinas SSH (`internal/machine`, nasceu 2026-08-01)

O maior dos três: **1777 linhas de código de produção** em 6 arquivos (contagem excluindo
`_test.go`: `machine.go` 824 + `identity.go` 356 + `install.go` 148 + `keys.go` 243 +
`detect.go` 113 + `secret.go` 93 — `wc -l` rodado por arquivo, 2026-08-16;
[16/08/2026] recontado: os números de `machine.go`/total tinham sido medidos ANTES de a
mesma leva de correções acrescentar +17 linhas de cabeçalho a `machine.go` — eram 807 e
1760, ver `wc -l internal/machine/*.go` sem `_test.go`). Nasceu como
registro simples das máquinas do `CUTUQUE_SSH_TARGETS` e cresceu para cobrir tudo que o
cadastro de máquina pelo app passou a exigir: identidades (usuário/senha por máquina, com
a senha opcionalmente cifrada em disco — a chave que decifra vem só de
`CUTUQUE_IDENTITY_KEY` no ambiente, nunca do disco), chave SSH própria por máquina
(geração ed25519 + `known_hosts` dedicado, fora do `~/.ssh` que as máquinas do
`hub.env` usam), instalação de chave via senha em modo one-shot, e detecção de SO remoto.
Machines têm duas origens: `Source=env` (do `hub.env`, imutável pelo app) e `Source=app`
(cadastrada pelo app, editável). Assim como board e reaper, **zero import cruzado** com
`session`/`registry`/`engine`/`board` — standalone de verdade. Quem fala com ele:
`cmd/hub/main.go` (bootstrap + liga a persistência via `NewRegistryAt`),
`internal/launcher/targets.go` (monta os `Target` de SSH a partir de cada `Machine`), e
4 arquivos de `internal/server` (`machines.go`, `machines_admin.go`, `identities.go`,
`launch.go`) somando as rotas de máquina e identidade. Sem doc próprio — nem
`board-protocol.md` nem um `machine-protocol.md` equivalente existem para ele.

## Métricas de forma — 2026-08-16

Números abaixo vieram de comandos rodados no dia da revisão, não de estimativa —
reproduza com o comando ao lado se quiser conferir daqui a um tempo.

**Rotas HTTP por domínio**, de `hub/internal/server/server.go` (único lugar onde o mux é
montado — `main.go` não registra rota nenhuma direto):

```
grep -n 'mux.Handle("' internal/server/server.go | grep -E '"[A-Z]+ /machines'    # 27
grep -n 'mux.Handle("' internal/server/server.go | grep -E '"[A-Z]+ /sessions'    # 12
grep -n 'mux.Handle("' internal/server/server.go | grep -E '"[A-Z]+ /board' \
  | grep -v board-protocol                                                        # 10
grep -n 'mux.Handle("' internal/server/server.go | grep -E '"[A-Z]+ /identities'  # 4
grep -n 'mux.Handle("' internal/server/server.go | grep -E '"[A-Z]+ /targets'     # 1
```

`machines` (27 rotas: CRUD de máquina, bridge de tmux com 8 rotas, fs com 4 rotas, pty,
adopt, scan/trust/install-key/detect-os) já é o maior domínio de rota do hub, maior que
`sessions` (12). `identities` (4) e `targets` (1) ficam de fora da contagem de `machines`
por não começarem com esse prefixo de path — vale lembrar disso se alguém for somar
"tudo que é `machine`" e comparar com o total de rotas do arquivo.

**Linhas por pacote novo** (produção, sem `_test.go`, `wc -l` por arquivo): `board` não
foi recontado linha a linha nesta revisão (fora do escopo do Achado 3); `machine` = 1777
(detalhado acima, corrigido de 1760 em 16/08/2026); `reaper` tem 1 arquivo de produção,
não recontado aqui.

## Bypasses conhecidos do contrato "só o Engine escreve estado" — 2026-08-16

O contrato central do projeto (`engine.go:1-3`: "É a única peça que escreve o estado das
sessões", reforçado no comentário de `Remove` em `registry.go:551`) tinha, quando esta
seção foi escrita nesta revisão, três exceções conhecidas — todas dentro do próprio
`internal/launcher/launcher.go` — nenhuma delas escondida de propósito, mas nenhuma
documentada até então:

| Método | Linha (~) | O que faz | Proteção |
|---|---|---|---|
| `Interrupt` | 927 | Mata o processo e chama `reg.UpdateStateIfCurrent(id, StateRunning, StateError)` direto no Registry | **Tem CAS** — só aplica se o estado atual ainda for o esperado |
| `Adopt` | 583 | Registra a sessão adotada via `reg.AddIfAbsent(s)` direto no Registry | **Atômico** — `AddIfAbsent` já resolve a corrida de dois `Adopt` simultâneos |
| `Resolve` | 831 | Marca `done` via `reg.UpdateStateIfCurrent(id, StateNeedsYou, StateDone)` direto no Registry | **[16/08/2026] Tem CAS** — perdedora devolve `*StaleStateError{Current}` em vez de sobrescrever (ver complemento abaixo) |

Nos três casos a transição não passa pelo Engine, então **não vira histórico** (`e.record()`
só existe em `engine.go` — o que não passa pelo Engine não aparece no timeline do
Postgres). `Interrupt` e `Adopt` usam operações já atômicas da própria Registry, então o
risco é só "não vira histórico"; `Resolve` era o único caso com risco real de corrida (dois
`Resolve` ou um `Resolve` cruzando com uma transição do Engine podiam pisar um no outro) —
ver `[16/08/2026]` abaixo: isso foi endereçado, mas a ausência de histórico continua.

**[16/08/2026] Complemento — `Resolve` ganhou CAS:** decisão da dona do projeto (Opção 2,
"falha e conta"): `Launcher.Resolve` trocou a escrita cega por
`reg.UpdateStateIfCurrent(id, StateNeedsYou, StateDone)`. A escrita perdedora não sobrescreve
mais em silêncio — devolve `*launcher.StaleStateError{Current: <estado vencedor>}` (embrulha o
sentinel `ErrStaleState` via `Unwrap`, então `errors.Is` continua funcionando para quem só
checa o código). `ResolveHandler` (`hub/internal/server/launch.go`) traduz isso em HTTP:
`errors.As` extrai o estado vencedor e responde 409 `{"error":"stale_state","current_state":
"<estado>"}` — sessão inexistente continua distinguível como 404 `unknown_session` (dois
casos, dois status). `Resolve` continua sendo bypass do contrato "só o Engine escreve estado"
(a transição ainda não vira histórico — `e.record()` não roda) e continua sem lock estendido
entre o CAS falhar e o `Get` de desempate 404-vs-409 (mesma looseness do `Interrupt`) — isso
é intencional para esta leva, não uma regressão. Só o 409 de `Resolve` carrega `current_state`
hoje; os outros 409 `stale_state` (`Approve`/`Deny`/`Answer`/`Interrupt`) continuam sem estado
extra — inconsistência aceita, não um esquecimento.

**[16/08/2026] Complemento — mais dois bypasses, fora do `launcher.go`:** a tabela acima
listava só os três de cima; faltavam dois que já eram conhecidos quando esta seção foi
escrita (um deles é literalmente o achado do card `a87e93b01123fa13`):

| Método | Linha (~) | O que faz | Proteção |
|---|---|---|---|
| `Registry.SetPane` (`registry.go`) | 390–412 | No switch de evicção (sessão que perde a pane pra uma sessão nova no mesmo terminal), decide o estado da evictada sozinho: `NeedsYou→Done` (391–402) ou `Running→Idle` (403–411) — mesma classe de decisão que `targetState()` faz em `engine.go`, só que dentro do Registry | Protegida só pelo `r.mu.Lock()` do próprio `SetPane` — não é corrida de dados, mas é decisão de estado fora do Engine (card `a87e93b01123fa13`) |
| `reaper.resolve` → `Registry.Forget` (`reaper.go`) | 233–234 | Ceifa sessão sem transcript no disco apagando direto do Registry (`rp.reg.Forget`, `delete(r.byID, id)`); só DEPOIS chama `rp.eng.RecordForgotten(id)`, que é só histórico (não decide estado) | **Tem CAS** — `Forget` só apaga se o estado atual ainda for o `from` esperado |

Estes dois não escrevem histórico da mesma forma que os três de cima (a transição de
`SetPane` nem chega a existir como evento; `Forget` grava um evento no histórico, mas
DEPOIS de o Registry já ter decidido/apagado — a ordem é que é o bypass). Mesma postura
do parágrafo acima: fora do escopo desta revisão resolver, só documentar.

---

**Última revisão:** 2026-08-16. Seções originais de 2026-07-02 mantidas como estavam,
com notas inline datadas onde a realidade divergiu; seções novas acima cobrem o que não
existia ainda quando o documento foi escrito.
