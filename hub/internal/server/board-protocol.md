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
cutuque task list                 # lista as atividades DESTA sessão e em que coluna estão
cutuque task add "<título>"       # cria uma atividade nova (entra em "A fazer")
cutuque task move <id> <coluna>   # move uma atividade (colunas acima)
```

Exemplos:

```bash
cutuque task add "implementar login OAuth"
cutuque task list
cutuque task move 6722dd9f1a5f2ac2 em_progresso
```

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

> **Cutuque Board.** Você participa de um quadro Kanban compartilhado via a CLI
> `cutuque`. **Antes de iniciar qualquer tarefa**, rode `cutuque task list` para
> ver suas atividades e onde estão. Registre atividades pendentes com
> `cutuque task add "…"`. Conforme progride, mova o card:
> `cutuque task move <id> em_progresso` ao iniciar → `feito` ao terminar (aguardando
> revisão) → `em_revisao` ao revisar → `concluido` ao concluir. A identificação da
> sessão (grupo tmux + sessão) é automática — não passe tags. Mantenha o quadro
> sempre atualizado.

## Configuração

A CLI fala com o hub (default `http://127.0.0.1:8787`, token `dev-token` em dev).
Sobrescreva por ambiente quando necessário:

```bash
export CUTUQUE_HUB=192.0.2.10:8787   # ou CUTUQUE_DECK_HUB
export CUTUQUE_TOKEN=<seu-token>
```
