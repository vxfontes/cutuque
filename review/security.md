# Achados de Segurança — Cutuque

## SEC-102 — corrida entre heartbeat de foreground e transição para background pode suprimir push indefinidamente
**Severidade:** R2 | **OWASP:** A04:2021 – Insecure Design (falha de design em um controle de segurança/alerta, não injeção clássica)
**Localização:** `app/CutuqueApp/ForegroundReporter.swift:36-50` (heartbeat `active:true` + envio imediato de `active:false` ao sair), `hub/internal/notifier/notifier.go:92-98` (`SetForeground`, `atomic.Int64` sem sequência lógica), `hub/internal/notifier/notifier.go:267-272` (`fanout`, ponto onde a supressão é aplicada)
**Detectado:** 2026-07-03 | **Status:** open

**Descrição:**
A feature de supressão de push por foreground (feature #3 desta leva) depende de duas requisições HTTP INDEPENDENTES e sem sequência lógica entre si:
- Heartbeat: `active:true` a cada 60s enquanto o app está `.active` (`ForegroundReporter.swift:36-43`).
- Saída: `active:false` disparado imediatamente ao entrar em `.background`/`.inactive` (`ForegroundReporter.swift:45-50`), sem esperar o cancelamento do heartbeat em voo terminar.

`Notifier.SetForeground` (`notifier.go:92-98`) só faz `n.foregroundUntil.Store(...)` — um `atomic.Int64` garante que o acesso à variável é atômico, mas não impõe nenhuma ordem causal entre requests concorrentes: o hub aplica o que CHEGA por último na rede, não o que aconteceu por último no cliente. Qualquer transição momentânea para `.inactive` (Control Center, app switcher, chamada entrando, prompt de Face ID/passcode) já é suficiente para dispersar um par de requests (`false` seguido de `true`, ou vice-versa) sem nenhum debounce ou espera entre eles — não é um cenário raro amarrado só ao ciclo de 60s do heartbeat.

Se uma requisição `active:true` (heartbeat em voo no momento em que o app foi para background) chegar ao hub DEPOIS de uma `active:false` mais recente, o hub reabre a janela de supressão por até 150s (`foregroundTTL`) mesmo com o app em background — suprimindo silenciosamente pushes de `needs_you`/`done`/`error` exatamente quando a usuária não está olhando o app e mais precisa ser avisada. Isso inverte o objetivo de segurança/confiabilidade da feature ("nunca perder o cutucão crítico quando o app não está aberto").

**Fix recomendado:**
1. Incluir uma sequência/timestamp monotônico do cliente no corpo de `POST /app/foreground` (ex.: `{"active": bool, "at": <ms epoch>}`).
2. `Notifier` guarda o `at` da última atualização aceita ao lado de `foregroundUntil`; ignora qualquer update cujo `at` seja mais antigo que o último aceito — restaura ordem LÓGICA (a que importa) em vez de depender da ordem de chegada na rede.
3. Alternativa complementar (não substitui o fix acima): no cliente, `stopHeartbeat()` poderia aguardar (`await task?.value` via `Task<Void, Never>` com cancelamento cooperativo observado) a conclusão da chamada em voo antes de disparar `active:false`, reduzindo a janela de corrida local — mas não resolve reordenamento em nível de rede sozinho.

## SEC-101 — OS command injection via `id` (Adopt) no SSHTarget
**Severidade:** R1 | **OWASP:** A03:2021 – Injection
**Localização:** `hub/internal/adapter/claudecode/target.go:344-374` (`remoteClaudeCommand`, `singleQuote`), exposto via `hub/internal/launcher/launcher.go:207-227` (`Adopt`) e `:332-373` (`resume`, linha 348: `tgt.Start(l.baseCtx, s.ID, s.Cwd)`), aceito sem validação em `hub/internal/server/launch.go:50-77` (`AdoptHandler`, valida só `req.ID != ""`)
**Detectado:** 2026-07-03 | **Status:** RESOLVIDO (2026-07-03)

**Resolução (2026-07-03):**
Os três pontos do fix recomendado foram aplicados e verificados:
1. `remoteClaudeCommand` (`target.go`) reescrito com o idioma `bash -lc 'exec "$0" "$@"' <argv...>`, cada arg single-quoted individualmente — o `bash` interno não reparseia mais os args como shell.
2. `Launcher.Adopt` (`launcher.go`) valida `id` contra `sessionIDPattern = ^[0-9a-fA-F-]{8,64}$` → `ErrInvalidSessionID`; `AdoptHandler` mapeia para `400 invalid_session_id`.
3. Comentário de `singleQuote` atualizado (protege UM nível; ver `remoteClaudeCommand` para o caso aninhado).

Testes de regressão: `TestRemoteClaudeCommandNeutralizesInjection` (5 payloads: `;`, `&&`, `$()`, backticks, `$()` isolado — nenhum executa, arg chega intacto), `TestAdoptRejectsInvalidID`, `TestAdoptInvalidSessionID` (server → 400). Verificado no hub deployado: id malicioso → 400 `invalid_session_id`, sem artefato de injeção no servidor.

**Verificação de não-regressão (2026-07-03, leva de histórico/live/foreground):**
`SSHTarget.Transcript` (`transcript.go:124-127`) reusa o MESMO `singleQuote`/único nível de shell (sem `bash -lc` aninhado) e depende de `Launcher.Adopt` já ter validado `id` via `sessionIDPattern` antes de qualquer chamada (único call site, confirmado via grep). `Live`/`live.go` não recebe nenhum input do cliente — script é uma constante Go, `machine` só indexa o mapa fixo de targets. **SEC-101 não regrediu.**

**Descrição:**
`POST /machines/{machine}/adopt` aceita `id` livre do cliente (app) e grava como `Session.ID` no registry sem validar formato. Quando essa sessão (idle, sem handle vivo) recebe `POST /sessions/{id}/input`, `Launcher.SendText` cai em `resume()`, que chama `tgt.Start(ctx, s.ID, s.Cwd)` com `s.ID` = o `id` fornecido pelo cliente. Para `SSHTarget`, isso vira `--resume <id>` dentro de `remoteClaudeCommand`, que monta:

```
bash -lc '<claude -p --resume <id> --input-format ... --verbose>'
```

O `id` entra na string que é o ARGUMENTO de um `bash -lc` ANINHADO. `singleQuote` escapa corretamente para o shell de login que o `sshd` invoca (nível 1), mas esse nível 1 apenas entrega a string inteira, já sem as aspas externas, como o argumento `-c` do `bash` interno (nível 2) — que a REPARSEIA como uma nova linha de comando (word-splitting, `;`, `&&`, `$()`, etc. voltam a valer). Ou seja, o escape de `singleQuote` protege só o nível externo; o `id` nunca é isolado como um token opaco no nível interno.

PoC local (fora do sandbox de produção, sem tocar em nenhuma máquina real) confirmou execução: com `id = "X; touch <arquivo> #"`, o comando resultante, executado como o `sshd` executaria (`shell -c "<string>"`), efetivamente rodou o `touch` injetado.

Antes desta feature, `s.ID` só podia vir do próprio `claude` (evento `session_started`, UUID gerado pela CLI) — nunca de input direto do cliente. O `Adopt` introduz a primeira via pela qual um chamador com o `CUTUQUE_TOKEN` controla literalmente o conteúdo do `--resume <id>`, alcançando RCE como o usuário SSH remoto em qualquer máquina cadastrada como `SSHTarget`. `LocalTarget` NÃO é afetado (Go `exec.Command` não passa por shell, `id` vira um argv isolado).

**Fix recomendado:**
1. Corrigir a construção do comando remoto para não reparsear o payload num shell aninhado — usar o idioma `bash -lc 'exec "$0" "$@"' <argv0> <argv1> ...`, quotando CADA argumento individualmente (inclusive os fixos), em vez de juntar tudo numa string e quotar o conjunto:

```go
func remoteClaudeCommand(claudeCmd, resumeID, cwd string) string {
    args := []string{claudeCmd, "-p"}
    if resumeID != "" {
        args = append(args, "--resume", resumeID)
    }
    args = append(args,
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--permission-mode", "default",
        "--permission-prompt-tool", "stdio",
        "--verbose",
    )
    quoted := make([]string, len(args))
    for i, a := range args {
        quoted[i] = singleQuote(a)
    }
    cmd := "bash -lc " + singleQuote(`exec "$0" "$@"`) + " " + strings.Join(quoted, " ")
    if cwd != "" {
        cmd = "cd " + singleQuote(cwd) + " && " + cmd
    }
    return cmd
}
```
   Validado localmente: com o mesmo `id` malicioso, o comando resultante não executa o `touch` injetado (o valor chega inteiro e literal em `$@`, sem ser reinterpretado pelo bash interno).

2. Defesa em profundidade em `AdoptHandler`/`Launcher.Adopt`: validar `id` contra o formato real de session id do Claude Code (ex.: `^[0-9a-fA-F-]{8,64}$`) e rejeitar com 400 se não bater — evita que qualquer variação futura de construção de comando reabra a mesma classe de bug.
3. Atualizar o comentário de `singleQuote` (target.go:369-371), que hoje diz não ser um escapador genérico para input externo — hoje é exatamente isso que ele faz, então o comentário deve refletir a garantia real após o fix (isolamento correto por token via `"$@"`, não por concatenação+quote único).
</content>
