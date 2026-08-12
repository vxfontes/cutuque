package claudecode

// Telas capturadas de verdade em 12/08/2026 com `tmux capture-pane -p`, uma por
// estado e por agente. São a fixture de toda a chain A: quando uma TUI mudar de
// string, é aqui que se recalibra (método gravado em
// memory/cutuque/backend/Backend — Estado do Pane por Agente (claude, codex, opencode).md).
//
// Versões calibradas: claude 2.1.228 · codex 0.147.0 · opencode 1.18.16.

const telaClaudeTrabalhando = `> resumir o arquivo

✻ Pondering… (8s · ↑ 1.2k tokens · esc to interrupt)
`

const telaClaudeEsperando = `Do you want to proceed?
❯ 1. Yes
  2. No, and tell Claude what to do differently
`

// Ocioso do Claude: o status é PASSADO ("Cogitated for 10s"), sem parênteses de
// timer vivo — é por isso que work_re exige o "\(".
const telaClaudeOciosa = `⏺ Pronto, resumi o arquivo.

  Cogitated for 10s
>
`

// codex trabalhando: timer vivo confirmado (29s → 31s → 33s em leituras de 2s).
// Casa nas DUAS regras do Claude: work_re em "(29s" e "esc to interrupt".
const telaCodexTrabalhando = `• Working (29s • esc to interrupt)

  ⋮ lendo o arquivo
`

const telaCodexOciosa = `› pergunte algo

  gpt-5-codex · ~/Desktop/coding/personal/cutuque
`

// O portão de confiança: sessão TRAVADA esperando tecla, para sempre. Nada aqui
// casa com as regras atuais, então hoje é classificada como "idle" (verde,
// "concluído") — o caso que o formulário de novo terminal vai criar toda hora.
const telaCodexPortaoDeConfianca = `Do you trust the contents of this directory?

› 1. Yes, continue
  2. No, quit
`

// opencode trabalhando: "esc interrupt" SEM o "to", mais o spinner de blocos.
const telaOpencodeTrabalhando = `⬝⬝⬝■■■  Build

  esc interrupt
`

// opencode ocioso DEPOIS de concluir: imprime a duração ("· 3.2s"). Sem o "\(" no
// work_re, esta tela viraria "running" para sempre. É a armadilha número 1.
const telaOpencodeOciosa = `▣ Build · claude-sonnet-4-5 · 3.2s

  Ask anything...
  tab agents  ctrl+p commands
`
