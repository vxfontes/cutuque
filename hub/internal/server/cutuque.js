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
// Identidade da sessão. Prioridade: override explícito (CUTUQUE_GROUP/
// CUTUQUE_SESSION) > detecção pelo tmux (group = nome do socket em $TMUX,
// session = sessão atual) > fallback (hostname/default). O override é útil quando
// a CLI roda fora do tmux (ex.: um shell não-interativo) e o auto-detect não vê.
function tmuxIdentity(env = process.env, runCmd = defaultRun) {
  const ovGroup = (env.CUTUQUE_GROUP || '').trim();
  const ovSession = (env.CUTUQUE_SESSION || '').trim();

  let group = ovGroup;
  let session = ovSession;

  if ((!group || !session) && env.TMUX) {
    if (!group) group = basename(String(env.TMUX).split(',')[0]) || '';
    if (!session) {
      try { session = String(runCmd("tmux display-message -p '#S'")).trim(); } catch { /* fallback */ }
    }
  }

  return {
    group: group || env.HOSTNAME || 'local',
    session: session || 'default',
  };
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
    async moveTask(id, column, actor) { return req('PATCH', `/board/tasks/${id}`, { column, actor }); },
    async patchTask(id, patch) { return req('PATCH', `/board/tasks/${id}`, patch); },
    async addComment(id, author, text) { return req('POST', `/board/tasks/${id}/comments`, { author, text }); },
    async search(q) { return (await req('GET', '/board/search?q=' + encodeURIComponent(q))).tasks || []; },
    async archive() { return (await req('GET', '/board/archive')).weeks || []; },
    async closeWeek() { return req('POST', '/board/close', {}); },
  };
}

// ===== src/commands.js =====
const COLS = ['a_fazer', 'em_progresso', 'feito', 'em_revisao', 'concluido'];
const LABEL = { a_fazer: 'A fazer', em_progresso: 'Em progresso', feito: 'Feito', em_revisao: 'Em revisão', concluido: 'Concluído' };

// Escopo do list/week. Padrão: o AMBIENTE (grupo) da identidade — o orquestrador
// e os subagentes compartilham a visão do ambiente. Flags ampliam/estreitam:
//   --all            todos os ambientes
//   --group <nome>   um ambiente específico
//   --session|--mine só a minha sessão
function resolveScope(identity, flags = {}) {
  if ('all' in flags) return { kind: 'all' };
  if (flags.group) return { kind: 'group', group: flags.group };
  if ('session' in flags || 'mine' in flags) return { kind: 'session', group: identity.group, session: identity.session };
  return { kind: 'group', group: identity.group };
}
function inScope(t, s) {
  if (s.kind === 'all') return true;
  if (s.kind === 'group') return t.group === s.group;
  return t.group === s.group && t.session === s.session;
}
function scopeLabel(s) {
  if (s.kind === 'all') return 'todos os ambientes';
  if (s.kind === 'group') return s.group;
  return `${s.group}/${s.session}`;
}
function cardLine(t) {
  const marks = [];
  const who = t.role || t.type;
  if (who) marks.push(who);
  if (t.encalhada) marks.push('encalhada');
  const nc = (t.comments || []).length;
  if (nc) marks.push(`${nc}c`);
  return `  ${t.id}  ${t.title}${marks.length ? `  (${marks.join(', ')})` : ''}`;
}

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
  // list: board atual (não-arquivados, INCLUINDO encalhados) no escopo escolhido.
  async list(cli, { flags = {} } = {}) {
    const scope = resolveScope(cli.identity, flags);
    const all = await cli.client.listTasks();
    const mine = all.filter((t) => inScope(t, scope));
    cli.out(`Board ${scopeLabel(scope)} (${mine.length}):`);
    for (const col of COLS) {
      const items = mine.filter((t) => t.column === col);
      if (!items.length) continue;
      cli.out(`\n${LABEL[col]}:`);
      for (const t of items) cli.out(cardLine(t));
    }
  },
  // show: detalhe completo de um card (descrição, linha do tempo e TODOS os
  // comentários) — para o agente opinar com base no histórico. Procura no board
  // ativo e, se não achar, no arquivo (semanas passadas).
  async show(cli, id) {
    const all = await cli.client.listTasks();
    let t = all.find((x) => x.id === id);
    if (!t) {
      const weeks = await cli.client.archive();
      for (const w of weeks) {
        const f = (w.tasks || []).find((x) => x.id === id);
        if (f) { t = f; break; }
      }
    }
    if (!t) throw new Error(`card não encontrado: ${id}`);
    const dt = (x) => (x ? new Date(x).toLocaleString('pt-BR') : '—');
    const meta = [`Coluna: ${LABEL[t.column] || t.column}`];
    if (t.type) meta.push(`Tipo: ${t.type}`);
    if (t.role) meta.push(`Quem: ${t.role}`);
    cli.out(`${t.id}  ${t.title}`);
    cli.out(meta.join(' · '));
    cli.out(`Ambiente: ${t.group}/${t.session}${t.encalhada ? ' · ENCALHADA' : ''}`);
    if (t.description) cli.out(`\nDescrição:\n${t.description}`);
    cli.out(`\nDatas: criado ${dt(t.created_at)} · início ${dt(t.started_at)} · revisão ${dt(t.reviewed_at)} · fim ${dt(t.ended_at)}`);
    const acts = t.activity || [];
    if (acts.length) {
      cli.out(`\nAtividade:`);
      for (const a of acts) cli.out(`  - ${a.actor} ${a.action}${a.at ? ` (${dt(a.at)})` : ''}`);
    }
    const cs = t.comments || [];
    cli.out(`\nComentários (${cs.length}):`);
    if (!cs.length) cli.out('  (nenhum)');
    for (const c of cs) cli.out(`  - ${c.author}${c.created_at ? ` (${dt(c.created_at)})` : ''}: ${c.text}`);
  },
  // search: acha cards (ativos E arquivados) cujo título/descrição/comentário
  // contenha o termo. Escopo padrão = ambiente (--all cruza tudo).
  async search(cli, { flags = {}, args = [] } = {}) {
    const term = args.join(' ').trim();
    if (!term) throw new Error('uso: cutuque task search <termo>');
    const scope = resolveScope(cli.identity, flags);
    const all = await cli.client.search(term);
    const hits = all.filter((t) => inScope(t, scope));
    cli.out(`Busca "${term}" em ${scopeLabel(scope)} (${hits.length}):`);
    if (!hits.length) cli.out('  (nada)');
    const low = term.toLowerCase();
    for (const t of hits) {
      const where = [];
      if (String(t.title || '').toLowerCase().includes(low)) where.push('título');
      if (String(t.description || '').toLowerCase().includes(low)) where.push('descrição');
      if ((t.comments || []).some((c) => String(c.text || '').toLowerCase().includes(low))) where.push('comentário');
      const status = t.archived ? 'ARQUIVADO' : (LABEL[t.column] || t.column);
      cli.out(`  ${t.id}  ${t.title}  [${status}]${where.length ? `  (em: ${where.join(', ')})` : ''}`);
    }
  },
  // find: filtra o board ativo por --role / --column / --type (no escopo).
  async find(cli, { flags = {} } = {}) {
    const scope = resolveScope(cli.identity, flags);
    let hits = (await cli.client.listTasks()).filter((t) => inScope(t, scope));
    if (flags.role) hits = hits.filter((t) => (t.role || '') === flags.role);
    if (flags.column) hits = hits.filter((t) => t.column === flags.column);
    if (flags.type) hits = hits.filter((t) => (t.type || '') === flags.type);
    cli.out(`Find em ${scopeLabel(scope)} (${hits.length}):`);
    if (!hits.length) cli.out('  (nada)');
    for (const t of hits) cli.out(cardLine(t));
  },
  // mentions: lista os comentários que te mencionam (@nome) no seu escopo — a sua
  // "caixa de entrada". Nome vem de --agent (ou da identidade). Só board ativo.
  async mentions(cli, { flags = {} } = {}) {
    const scope = resolveScope(cli.identity, flags);
    const name = (flags.agent || cli.identity.role || cli.identity.type || '').trim();
    if (!name) throw new Error('informe seu nome: cutuque task mentions --agent <você>');
    const needle = '@' + name.toLowerCase();
    const all = await cli.client.listTasks();
    const hits = [];
    for (const t of all.filter((x) => inScope(x, scope))) {
      for (const c of t.comments || []) {
        if (String(c.text || '').toLowerCase().includes(needle)) hits.push({ t, c });
      }
    }
    cli.out(`Menções a @${name} em ${scopeLabel(scope)} (${hits.length}):`);
    if (!hits.length) cli.out('  (nenhuma)');
    for (const { t, c } of hits) {
      cli.out(`\n  ${t.id}  ${t.title}  [${LABEL[t.column] || t.column}]`);
      cli.out(`    ${c.author}: ${c.text}`);
    }
  },
  // week: acessa os concluídos ARQUIVADOS por semana. Sem label -> lista as semanas;
  // com label (ex: 2026-W28) -> mostra os cards daquela semana no escopo.
  async week(cli, { flags = {}, args = [] } = {}) {
    const scope = resolveScope(cli.identity, flags);
    const weeks = await cli.client.archive();
    const label = args[0];
    if (!label) {
      if (!weeks.length) { cli.out('Nenhuma semana arquivada ainda.'); return; }
      cli.out(`Semanas arquivadas (${scopeLabel(scope)}):`);
      for (const w of weeks) {
        const n = w.tasks.filter((t) => inScope(t, scope)).length;
        cli.out(`  ${w.label}  ${w.start} – ${w.end}  (${n} concluído${n === 1 ? '' : 's'})`);
      }
      cli.out(`\nuse: cutuque task week ${weeks[0].label}`);
      return;
    }
    const wk = weeks.find((w) => w.label === label);
    if (!wk) throw new Error(`semana não encontrada: ${label}`);
    const items = wk.tasks.filter((t) => inScope(t, scope));
    cli.out(`${wk.label} (${wk.start} – ${wk.end}) — ${scopeLabel(scope)} (${items.length}):`);
    for (const t of items) cli.out(cardLine(t));
  },
  // close-week: fecha a semana manualmente (arquiva concluídos + marca encalhados).
  // Normalmente roda sozinho (domingo 23:59); aqui é o gatilho manual.
  async closeWeek(cli) {
    const r = await cli.client.closeWeek();
    cli.out(`✓ semana fechada: ${r.archived} arquivado(s), ${r.stalled} encalhado(s)`);
  },
  async move(cli, id, column) {
    if (!COLS.includes(column)) throw new Error(`coluna inválida: ${column} (use: ${COLS.join(', ')})`);
    const actor = cli.identity.role || cli.identity.type || 'agente';
    await cli.client.moveTask(id, column, actor);
    cli.out(`✓ ${id} → ${LABEL[column]}`);
  },
};

// ===== bin/cutuque.js =====
const USAGE = `uso:
  cutuque task add "<título>" --agent <role> [--desc "<descrição>"]
  cutuque task list [--all | --group <nome> | --session]
  cutuque task show <id>                              # detalhe do card + TODOS os comentários
  cutuque task search <termo>                         # busca título+descrição+comentários (ativos E arquivados)
  cutuque task find [--role <r>] [--column <c>] [--type <t>]   # filtra o board ativo
  cutuque task mentions --agent <você>               # comentários que te mencionam (@você)
  cutuque task move <id> <a_fazer|em_progresso|feito|em_revisao|concluido>
  cutuque task comment <id> "<texto>" --agent <role>
  cutuque task desc <id> "<descrição>"
  cutuque task week [<label>] [--all | --group <nome> | --session]
  cutuque task close-week

--agent <role> = quem está fazendo (ex: marcus, luka, ludmilla). Obrigatório em add e comment.
list/week mostram por padrão o SEU ambiente (grupo). Encalhados aparecem no list.
week sem label lista as semanas arquivadas; com label (ex: 2026-W28) mostra os cards.`;

// Flags booleanas (não consomem o próximo argumento).
const BOOL_FLAGS = new Set(['all', 'session', 'mine']);

// Separa flags (--k v) dos argumentos posicionais.
function parseArgs(argv) {
  const flags = {};
  const pos = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      const key = argv[i].slice(2);
      const next = argv[i + 1];
      if (BOOL_FLAGS.has(key) || next === undefined || next.startsWith('--')) {
        flags[key] = '';
      } else { flags[key] = next; i++; }
    } else pos.push(argv[i]);
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
      await commands.list(cli, { flags });
    } else if (action === 'show') {
      const [id] = pos;
      if (!id) throw new Error('uso: cutuque task show <id>');
      await commands.show(cli, id);
    } else if (action === 'search') {
      await commands.search(cli, { flags, args: pos });
    } else if (action === 'find') {
      await commands.find(cli, { flags });
    } else if (action === 'mentions') {
      await commands.mentions(cli, { flags });
    } else if (action === 'week') {
      await commands.week(cli, { flags, args: pos });
    } else if (action === 'close-week') {
      await commands.closeWeek(cli);
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
