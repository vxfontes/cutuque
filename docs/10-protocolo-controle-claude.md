# 10 — Protocolo de controle do Claude Code (aprovação nativa)

> Verificado empiricamente em 2026-07-02 contra o CLI **2.1.198** (probe em
> `scratchpad/probe_control.py`; fixtures reais em
> `hub/internal/adapter/claudecode/testdata/`). É o mecanismo que a Fase 3 usa
> para **aprovar/negar de longe** sem tmux.

## Como lançar uma sessão controlável

```bash
claude -p \
  --input-format stream-json \
  --output-format stream-json \
  --permission-mode default \
  --permission-prompt-tool stdio \
  --verbose
```

- `--permission-prompt-tool stdio` é a chave: instrui o CLI a **perguntar via
  stdout/stdin** (protocolo de controle) em vez de decidir sozinho.
- O **prompt inicial vai pelo stdin** (não como argumento), como user message:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"seu prompt aqui"}]}}
```

- Mensagens subsequentes pelo mesmo stdin = **multi-turn** (é o que dá o
  `send_text` de graça).

## O pedido de permissão (CLI → hub, stdout)

Quando uma ferramenta não é coberta pelas regras de permissão, o CLI **pausa** e emite:

```json
{"type":"control_request","request_id":"553dacfc-…",
 "request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash",
            "input":{"command":"touch x.txt","description":"Create empty probe file"},
            "description":"Create empty probe file",
            "permission_suggestions":[…]}}
```

## A resposta (hub → CLI, stdin)

**Aprovar** (a ferramenta executa em seguida — verificado):

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<o mesmo>",
 "response":{"behavior":"allow","updatedInput":{<input original>}}}}
```

**Negar**:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<o mesmo>",
 "response":{"behavior":"deny","message":"negado pela usuária via Cutuque"}}}
```

## Armadilhas descobertas no probe

1. **Regras de permissão vêm antes do prompt-tool** — comandos no allowlist do
   usuário (ex: `git`, `ls`, `curl`) executam sem `control_request`. O hub só
   recebe pedido do que as regras não cobrem. Comportamento correto (menos
   fricção), mas os testes precisam provocar uma ferramenta fora do allowlist.
2. **`echo` passou sem pedido** mesmo fora do allowlist explícito — há
   auto-allow de comandos considerados seguros. Não contar com comando X
   "sempre pedir permissão" em testes; usar fixtures.
3. O stream inclui eventos `system` (hooks, thinking) e `rate_limit_event` —
   o parser ignora sem erro (já coberto na Fase 2).

## Mapeamento no Cutuque

| Protocolo | Evento normalizado | Estado |
|-----------|--------------------|--------|
| `control_request/can_use_tool` | `permission_requested` (Data = resumo humano, ControlID = request_id) | → `needs_you` + `pending_prompt` |
| approve/deny do app | `user_responded` | → `running` |
| user message via stdin | `user_responded` | → `running` |
