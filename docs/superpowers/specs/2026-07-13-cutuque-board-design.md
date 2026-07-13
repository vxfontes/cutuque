# Cutuque Board — Design

**Data:** 2026-07-13
**Status:** aprovado (brainstorming) — pronto para plano de implementação

## Resumo

Um **quadro Kanban — "Trello dos agentes"** — como uma nova página no dashboard (Command Center) do Cutuque, hospedado no hub. Diferente do board de *status* de sessão (running/needs_you/…), este rastreia **atividades/tarefas** de trabalho. Cada agente, de dentro da sua sessão de terminal, **consulta o quadro antes de agir**, cria suas atividades e as move pelas colunas conforme progride — e tudo aparece consolidado e ao vivo no dashboard, onde a usuária também pode arrastar cards.

## Objetivo e papel

- **Papel:** rastrear o trabalho dos agentes em um Kanban compartilhado, alimentado pelos próprios agentes via CLI e visível/manipulável no dashboard.
- **Complementa** o board de status de sessão (não o substitui): status = "como a sessão está agora"; board = "quais atividades existem e em que estágio estão".

## Restrição de compatibilidade (requisito de primeira classe)

Estritamente **aditivo**. O board de status (Sessões), os apps iOS/watchOS e o comportamento existente do hub **continuam idênticos** — zero regressão.
- Novos endpoints REST (`/board*`), novo storage, novos eventos WS e nova página no dashboard são **aditivos**.
- Nenhuma alteração de contrato/comportamento existente. Nenhuma mudança em `app/`.
- Critério de aceite: com o board ligado ou não, tudo que já existia se comporta igual; `go test ./...` verde.

## Modelo de dados

Card (tarefa do quadro):

```
Task {
  id         string     // gerado pelo hub (uuid/curto)
  title      string     // texto da atividade
  column     string     // a_fazer | em_progresso | feito | em_revisao | concluido
  group      string     // tag 1: nome do grupo tmux
  session    string     // tag 2: nome da sessão tmux
  created_at time.Time  // RFC3339
  updated_at time.Time  // RFC3339
}
```

- **Colunas (ordem):** `a_fazer` → `em_progresso` → `feito` → `em_revisao` → `concluido`.
  - `a_fazer`: pendente
  - `em_progresso`: agente fazendo
  - `feito`: terminou, aguardando revisão
  - `em_revisao`: sendo revisado
  - `concluido`: revisão passou / concluído de fato
- **Identificação por 2 tags:** `group` (grupo tmux) + `session` (sessão tmux). Permite ver/filtrar de qual grupo/sessão é cada card.

## Componentes

Três unidades com fronteiras claras:

1. **Hub — Board store + API (Go).**
   - **Store durável**: arquivo JSON no diretório de dados do hub (ex.: `board.json`), carregado no boot e salvo a cada mutação. Sem dependência de Postgres. Escritor único protegido por mutex.
   - **REST (aditivo, protegido por token como o resto):**
     - `GET /board` → todos os cards (lista).
     - `POST /board/tasks` → cria card `{title, group, session}` (coluna inicial `a_fazer`), devolve o card com `id`.
     - `PATCH /board/tasks/{id}` → move/edita (`{column?, title?}`).
     - `DELETE /board/tasks/{id}` → remove.
   - **WS (aditivo):** no MESMO WebSocket (`/ws`), novos eventos: `board_snapshot` (lista completa ao conectar), `board_updated` (upsert de um card), `board_removed` (`{id}`). Clientes que não conhecem esses tipos os ignoram (contrato atual intacto).

2. **CLI `cutuque` (Node, o que o agente usa).**
   - Roda no terminal/tmux do agente. Comandos:
     - `cutuque task add "título"` → cria card em `a_fazer` (tags automáticas), imprime o `id`.
     - `cutuque task list` → lista os cards **desta sessão** (por `group`+`session`) e sua coluna — o agente consulta antes de agir.
     - `cutuque task move <id> <coluna>` → move o card.
   - **Identificação automática do tmux:** `session` via `tmux display-message -p '#S'`; `group` via o socket tmux em uso (`-L <grupo>`, derivado de `$TMUX`). Fallback claro quando fora do tmux (usa hostname/"default" e avisa).
   - Config de hub/token por env (mesmo padrão do deck: `CUTUQUE_DECK_HUB`/`CUTUQUE_TOKEN` ou equivalente `CUTUQUE_HUB`).

3. **Dashboard — página "Board".**
   - **Navegação:** o Command Center ganha duas abas — "Sessões" (o board de status atual) e "Board" (o Kanban). Servido pelo hub (mesma origem), responsivo.
   - **Kanban 5 colunas**, cards com título + tags (grupo/sessão) + tempo relativo, ao vivo pelos eventos WS de board.
   - **Drag-and-drop**: arrastar um card entre colunas dispara `PATCH /board/tasks/{id}`. Filtro por grupo/sessão.

## Interações / fluxo do agente

Protocolo que cada agente segue (ensinado pelo .md de instrução):
1. **Antes de começar**: `cutuque task list` para ver as atividades desta sessão e onde estão.
2. **Registrar atividades**: `cutuque task add "…"` para cada atividade pendente (entra em `a_fazer`).
3. **Ao iniciar** uma atividade: `move <id> em_progresso`.
4. **Ao terminar** (pronto, aguardando revisão): `move <id> feito`.
5. **Ao revisar**: `move <id> em_revisao`.
6. **Ao concluir** (revisão passou): `move <id> concluido`.

A usuária também pode arrastar cards no dashboard (ex.: aprovar → `concluido`). Agentes e humana compartilham o mesmo quadro.

## Instrução para os agentes (.md)

Documento `docs/board-protocol.md` com:
- O propósito do quadro e as 5 colunas/semântica.
- Os comandos da CLI e exemplos.
- O protocolo passo-a-passo acima.
- Um bloco pronto para colar no `CLAUDE.md`/regras de cada agente (ou como skill), instruindo a consultar o board antes de agir e mover ao progredir/terminar/revisar/concluir.

## Onde vive o código

```
board/                         # CLI cutuque (Node, ESM, dep: só o necessário)
  package.json
  src/                         # config, tmuxIdentity, hubClient(REST), commands
  bin/cutuque.js               # entrypoint da CLI
  test/                        # node:test
hub/internal/board/            # store durável (JSON) + modelo Task (Go)
hub/internal/server/board.go   # handlers REST /board*
hub/internal/server/ws.go      # (aditivo) eventos board_* no WS existente
hub/internal/server/dashboard.html  # (aditivo) aba "Board" + Kanban + WS board
docs/board-protocol.md         # instrução para os agentes
```

(Nomes/arquivos exatos e assinaturas serão fixados no plano de implementação.)

## Escopo

**MVP**
- Store durável (JSON) + modelo Task no hub.
- REST `/board` (GET/POST/PATCH/DELETE) + eventos WS `board_*`.
- CLI `cutuque`: `task add`, `task list`, `task move` com identificação tmux.
- Dashboard: aba "Board" com Kanban 5 colunas, ao vivo, drag-and-drop, filtro por grupo/sessão.
- `docs/board-protocol.md`.

**Fora de escopo (por enquanto)**
- Reordenar cards dentro da coluna / prioridade explícita.
- Comentários/checklists no card, anexos.
- Métricas (tempo por coluna, throughput).
- Autenticação por agente distinta do token do hub.

## Riscos e mitigações

1. **Identificação do grupo tmux**: derivar o "grupo" do socket (`-L`) pode variar por setup. → A CLI detecta via `$TMUX`/`tmux display-message`; documenta o fallback e permite override por flag/env.
2. **Concorrência de escrita no JSON** (vários agentes ao mesmo tempo): → escritor único no hub sob mutex; a CLI só chama a API, nunca escreve o arquivo direto.
3. **Persistência simples (JSON) vs volume**: adequado para dezenas/centenas de cards; se crescer muito, migrar para Postgres (já disponível no hub) — decisão adiada, não bloqueia o MVP.
4. **WS compartilhado**: eventos `board_*` no mesmo socket dos eventos de sessão. → tipos novos e ignorados por clientes antigos; o dashboard filtra por `type`.
```
