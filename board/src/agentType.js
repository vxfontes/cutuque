// Detecta o tipo do agente que está rodando a CLI (claude|codex|opencode),
// para virar a 3ª tag do card. Auto-detect por env vars conhecidas, com
// override explícito por CUTUQUE_AGENT.

const KNOWN = ['claude', 'codex', 'opencode'];

export function detectAgent(env = {}) {
  // 1) Override explícito.
  const override = (env.CUTUQUE_AGENT || '').trim().toLowerCase();
  if (KNOWN.includes(override)) return override;

  // 2) Marcadores conhecidos por agente.
  if (env.CLAUDECODE || Object.keys(env).some((k) => k.startsWith('CLAUDE_CODE'))) return 'claude';
  if (Object.keys(env).some((k) => k.startsWith('CODEX'))) return 'codex';
  if (Object.keys(env).some((k) => k.startsWith('OPENCODE'))) return 'opencode';

  // 3) Dica genérica (alguns setups expõem AI_AGENT=claude|codex|...).
  const hint = (env.AI_AGENT || '').trim().toLowerCase();
  if (KNOWN.includes(hint)) return hint;

  // 4) Desconhecido.
  return '';
}
