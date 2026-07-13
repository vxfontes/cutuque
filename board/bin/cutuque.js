#!/usr/bin/env node
import { resolveConfig } from '../src/config.js';
import { tmuxIdentity } from '../src/tmuxIdentity.js';
import { createHubClient } from '../src/hubClient.js';
import { commands } from '../src/commands.js';

const USAGE = `uso:
  cutuque task add "<título>"
  cutuque task list
  cutuque task move <id> <a_fazer|em_progresso|feito|em_revisao|concluido>`;

async function main() {
  const [, , area, action, ...rest] = process.argv;
  if (area !== 'task') { console.log(USAGE); process.exit(rest.length ? 1 : 0); }

  const cfg = resolveConfig(process.env);
  const cli = {
    identity: tmuxIdentity(process.env),
    client: createHubClient(cfg),
    out: (s) => console.log(s),
  };

  try {
    if (action === 'add') {
      const title = rest.join(' ').trim();
      if (!title) throw new Error('faltou o título');
      await commands.add(cli, title);
    } else if (action === 'list') {
      await commands.list(cli);
    } else if (action === 'move') {
      const [id, column] = rest;
      if (!id || !column) throw new Error('uso: cutuque task move <id> <coluna>');
      await commands.move(cli, id, column);
    } else {
      console.log(USAGE); process.exit(1);
    }
  } catch (err) {
    console.error(`erro: ${err.message}`); process.exit(1);
  }
}
main();
