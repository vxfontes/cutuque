#!/usr/bin/env node
import { resolveConfig } from '../src/config.js';
import { tmuxIdentity } from '../src/tmuxIdentity.js';
import { detectAgent } from '../src/agentType.js';
import { createHubClient } from '../src/hubClient.js';
import { commands } from '../src/commands.js';

const USAGE = `uso:
  cutuque task add "<título>" --agent <role> [--desc "<descrição>"]
  cutuque task list [--all | --group <nome> | --session]
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
