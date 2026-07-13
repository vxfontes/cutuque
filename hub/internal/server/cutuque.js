#!/usr/bin/env node
import { execSync } from 'node:child_process';
import { basename } from 'node:path';

// ===== src/config.js =====
// Default aponta para o hub no TAILSCALE (rede interna) — assim os agentes usam
// a CLI sem precisar setar env nenhuma. A mantenedora sobrescreve com
// CUTUQUE_HUB=127.0.0.1:8787 quando desenvolve local.
const DEFAULT_HUB = 'http://192.0.2.10:8787';

function resolveConfig(env = {}) {
  let hubBaseUrl = env.CUTUQUE_HUB || env.CUTUQUE_DECK_HUB || DEFAULT_HUB;
  // Aceita "host:porta" além de URL completa: prefixa o esquema se faltar.
  if (!/^https?:\/\//i.test(hubBaseUrl)) hubBaseUrl = `http://${hubBaseUrl}`;
  return {
    hubBaseUrl,
    token: env.CUTUQUE_TOKEN || 'dev-token',
  };
}

// ===== src/tmuxIdentity.js =====
// Identidade da sessão a partir do tmux. group = nome do socket (tmux -L <group>),
// derivado do caminho do socket em $TMUX; session = nome da sessão atual.
function tmuxIdentity(env = process.env, runCmd = defaultRun) {
  if (!env.TMUX) {
    return { group: env.HOSTNAME || 'local', session: 'default' };
  }
  const socketPath = String(env.TMUX).split(',')[0];
  const group = basename(socketPath) || 'default';
  let session = 'default';
  try { session = String(runCmd("tmux display-message -p '#S'")).trim() || 'default'; } catch { /* fallback */ }
  return { group, session };
}

function defaultRun(cmd) {
  return execSync(cmd, { encoding: 'utf8' });
}

// ===== src/agentType.js =====
// Detecta o tipo do agente que está rodando a CLI (claude|codex|opencode),
// para virar a 3ª tag do card. Auto-detect por env vars conhecidas, com
// override explícito por CUTUQUE_AGENT.

const KNOWN = ['claude', 'codex', 'opencode'];

function detectAgent(env = {}) {
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

// ===== src/hubClient.js =====
function createHubClient({ hubBaseUrl, token, fetchImpl = fetch }) {
  const h = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  async function req(method, path, body) {
    const res = await fetchImpl(`${hubBaseUrl}${path}`, {
      method, headers: h, body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status}`);
    if (res.status === 204) return null;
    return res.json();
  }
  return {
    async listTasks() { return (await req('GET', '/board')).tasks || []; },
    async createTask(t) { return req('POST', '/board/tasks', t); },
    async moveTask(id, column) { return req('PATCH', `/board/tasks/${id}`, { column }); },
    async patchTask(id, patch) { return req('PATCH', `/board/tasks/${id}`, patch); },
    async addComment(id, author, text) { return req('POST', `/board/tasks/${id}/comments`, { author, text }); },
  };
}

// ===== src/commands.js =====
const COLS = ['a_fazer', 'em_progresso', 'feito', 'em_revisao', 'concluido'];
const LABEL = { a_fazer: 'A fazer', em_progresso: 'Em progresso', feito: 'Feito', em_revisao: 'Em revisão', concluido: 'Concluído' };

const commands = {
  async add(cli, title, { desc = '' } = {}) {
    const t = await cli.client.createTask({
      title,
      group: cli.identity.group,
      session: cli.identity.session,
      type: cli.identity.type || '',
      role: cli.identity.role || '',
      description: desc,
    });
    cli.out(`✓ criado ${t.id} em "A fazer": ${title}${cli.identity.role ? ` (${cli.identity.role})` : ''}`);
  },
  async comment(cli, id, text) {
    await cli.client.addComment(id, cli.identity.role || cli.identity.type || '?', text);
    cli.out(`✓ comentário adicionado em ${id} por ${cli.identity.role || cli.identity.type || '?'}`);
  },
  async desc(cli, id, text) {
    await cli.client.patchTask(id, { description: text });
    cli.out(`✓ descrição atualizada em ${id}`);
  },
  async list(cli) {
    const all = await cli.client.listTasks();
    const mine = all.filter((t) => t.group === cli.identity.group && t.session === cli.identity.session);
    cli.out(`Board de ${cli.identity.group}/${cli.identity.session} (${mine.length}):`);
    for (const col of COLS) {
      const items = mine.filter((t) => t.column === col);
      if (!items.length) continue;
      cli.out(`\n${LABEL[col]}:`);
      for (const t of items) cli.out(`  ${t.id}  ${t.title}`);
    }
  },
  async move(cli, id, column) {
    if (!COLS.includes(column)) throw new Error(`coluna inválida: ${column} (use: ${COLS.join(', ')})`);
    await cli.client.moveTask(id, column);
    cli.out(`✓ ${id} → ${LABEL[column]}`);
  },
};

// ===== bin/cutuque.js =====
const USAGE = `uso:
  cutuque task add "<título>" --agent <role> [--desc "<descrição>"]
  cutuque task list
  cutuque task move <id> <a_fazer|em_progresso|feito|em_revisao|concluido>
  cutuque task comment <id> "<texto>" --agent <role>
  cutuque task desc <id> "<descrição>"

--agent <role> = quem está fazendo (ex: marcus, luka, ludmilla). Obrigatório em add e comment.`;

// Separa flags (--k v) dos argumentos posicionais.
function parseArgs(argv) {
  const flags = {};
  const pos = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) { flags[argv[i].slice(2)] = argv[i + 1] ?? ''; i++; }
    else pos.push(argv[i]);
  }
  return { flags, pos };
}

async function main() {
  const [, , area, action, ...rest] = process.argv;
  if (area !== 'task' || !action) { console.log(USAGE); process.exit(area ? 1 : 0); }

  const { flags, pos } = parseArgs(rest);
  const cfg = resolveConfig(process.env);
  const cli = {
    identity: { ...tmuxIdentity(process.env), type: detectAgent(process.env), role: (flags.agent || '').trim() },
    client: createHubClient(cfg),
    out: (s) => console.log(s),
  };

  try {
    if (action === 'add') {
      const title = pos.join(' ').trim();
      if (!title) throw new Error('faltou o título');
      if (!cli.identity.role) throw new Error('--agent <role> é obrigatório no add');
      await commands.add(cli, title, { desc: flags.desc || '' });
    } else if (action === 'list') {
      await commands.list(cli);
    } else if (action === 'move') {
      const [id, column] = pos;
      if (!id || !column) throw new Error('uso: cutuque task move <id> <coluna>');
      await commands.move(cli, id, column);
    } else if (action === 'comment') {
      const [id, ...textParts] = pos;
      const text = textParts.join(' ').trim();
      if (!id || !text) throw new Error('uso: cutuque task comment <id> "<texto>" --agent <role>');
      if (!cli.identity.role) throw new Error('--agent <role> é obrigatório no comment');
      await commands.comment(cli, id, text);
    } else if (action === 'desc') {
      const [id, ...textParts] = pos;
      const text = textParts.join(' ').trim();
      if (!id || !text) throw new Error('uso: cutuque task desc <id> "<descrição>"');
      await commands.desc(cli, id, text);
    } else {
      console.log(USAGE); process.exit(1);
    }
  } catch (err) {
    console.error(`erro: ${err.message}`); process.exit(1);
  }
}
main();
