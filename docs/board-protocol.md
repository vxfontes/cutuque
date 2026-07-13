# Cutuque Board — Protocolo para agentes

O **Cutuque Board** é um quadro Kanban compartilhado das atividades dos agentes.
Cada sessão (você) registra suas atividades e as move pelas colunas conforme o
trabalho progride. Tudo aparece ao vivo no dashboard (`/dashboard`, aba **Board**),
onde a mantenedora também pode arrastar cards.

Você interage com o quadro pela CLI **`cutuque`** — ela roda no seu terminal e
**identifica sua sessão automaticamente** (grupo do tmux + nome da sessão), então
você nunca precisa passar tags.

## As 5 colunas (nesta ordem)

| Coluna | Quando usar |
|--------|-------------|
| `a_fazer` | atividade pendente, ainda não começada |
| `em_progresso` | você está trabalhando nela agora |
| `feito` | terminou o trabalho, **aguardando revisão** |
| `em_revisao` | está sendo revisada (por você ou por outro agente) |
| `concluido` | revisão passou / concluída de fato |

## Comandos

```bash
cutuque task list                                  # lista as atividades DESTA sessão e em que coluna estão
cutuque task add "<título>" --agent <role> [--desc "<descrição>"]   # cria (entra em "A fazer")
cutuque task move <id> <coluna>                    # move uma atividade
cutuque task comment <id> "<texto>" --agent <role> # adiciona uma observação no card
cutuque task desc <id> "<descrição>"               # define/atualiza a descrição do card
```

- **`--agent <role>` é OBRIGATÓRIO em `add` e `comment`** — é quem está fazendo
  (o sub-agente/orquestrador: `luka`, `ludmilla`, `marcus`, …). Vira o autor do
  comentário e o "quem" do card.
- `--desc` (opcional no `add`) e `cutuque task desc` definem a **descrição** (o
  texto longo do que está sendo feito, mostrado no detalhe do card).
- O **tipo do agente** (claude/codex/opencode) é detectado automaticamente; não
  precisa passar (override por `CUTUQUE_AGENT` se necessário).

Exemplos:

```bash
cutuque task add "implementar login OAuth" --agent marcus --desc "OAuth2 + refresh token, com testes"
cutuque task list
cutuque task move 6722dd9f1a5f2ac2 em_progresso
cutuque task comment 6722dd9f1a5f2ac2 "fluxo pronto, subindo pra review" --agent marcus
```

## Detalhe do card (dashboard)

No dashboard (aba **Board**), clicar num card abre o detalhe estilo Trello:
grupo/sessão/tipo, quem está fazendo (role), descrição, **linha do tempo**
(criado · início · revisão · fim) e a **aba de comentários** — que os agentes
alimentam via `cutuque task comment` e a usuária também pode adicionar ali.

## Protocolo (siga sempre)

1. **Antes de começar qualquer trabalho**, rode `cutuque task list` para ver o que
   já existe nesta sessão e onde está — evita duplicar e te orienta.
2. **Registre suas atividades**: para cada atividade pendente do que você vai fazer,
   `cutuque task add "…"` (entram em `a_fazer`).
3. **Ao iniciar** uma atividade → `cutuque task move <id> em_progresso`.
4. **Ao terminar** (pronto, aguardando revisão) → `cutuque task move <id> feito`.
5. **Ao revisar** (a sua ou de outro) → `cutuque task move <id> em_revisao`.
6. **Ao concluir** (revisão passou) → `cutuque task move <id> concluido`.

Sempre que terminar um passo, **lembre de mover o card** — o quadro só é útil se
refletir a realidade.

## Bloco para colar no CLAUDE.md / regras do agente

> **Cutuque Board (obrigatório).** Você participa de um Kanban compartilhado dos
> agentes via a CLI `cutuque`.
> **Config (uma vez):** `export CUTUQUE_HUB=192.0.2.10:8787` — sempre o hub no
> Tailscale; **não** use localhost; **não** precisa de token.
> **Antes de começar qualquer tarefa:** `cutuque task list` (veja o que já existe
> na sua sessão e onde está).
> **Registre o que vai fazer:** `cutuque task add "<atividade>" --agent <seu-role> [--desc "<detalhe>"]`.
> **Mova conforme progride:** `cutuque task move <id> em_progresso` (ao iniciar) →
> `feito` (terminou, aguardando review) → `em_revisao` (revisando) → `concluido`
> (concluído de fato).
> **Comente as observações:** `cutuque task comment <id> "<observação>" --agent <seu-role>`.
> `--agent <role>` (quem está fazendo: luka, marcus, ludmilla…) é **OBRIGATÓRIO** em
> `add` e `comment`. Grupo/sessão do tmux e o tipo (claude/codex/opencode) são
> detectados automaticamente. Mantenha o quadro sempre atualizado.

## Configuração (IMPORTANTE)

⚠️ **Use SEMPRE o hub no Tailscale — `192.0.2.10:8787`.** Não existe
`localhost`/`127.0.0.1:8787` pra você (aquilo é só o dev local da mantenedora).
Antes de usar a CLI, exporte no seu shell/tmux:

```bash
export CUTUQUE_HUB=192.0.2.10:8787
```

**Não precisa de token** — o board é aberto na rede interna (Tailscale, não
exposto). Sem `CUTUQUE_HUB` a CLI cai no default de dev (`127.0.0.1`) e **não
acha o hub**.
