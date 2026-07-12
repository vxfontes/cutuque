// deck/src/main.js
import { existsSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { resolveConfig } from './config.js';
import { createHubClient as realCreateHubClient } from './hubClient.js';
import { createUlanziLink as realCreateUlanziLink } from './ulanziLink.js';
import { createRenderer as realCreateRenderer } from './renderer.js';
import { openContext as realOpenContext } from './context.js';

// Log de descoberta, gated por um marcador: só ativo quando o arquivo
// <tmpdir>/cutuque-deck-debug existe. Serve para descobrir/verificar, com o
// deck real, o formato de `key`/`actionid` que o Ulanzi manda nos eventos
// add/run. Em produção (sem o marcador) é um no-op — zero ruído.
function makeDebugLogger() {
  const on = existsSync(join(tmpdir(), 'cutuque-deck-debug'));
  const file = join(tmpdir(), 'cutuque-deck-events.log');
  return (line) => { if (on) { try { appendFileSync(file, `${line}\n`); } catch { /* ignore */ } } };
}

export function startDeck({ env = process.env, argv = process.argv.slice(2), deps = {} } = {}) {
  const {
    createHubClient = realCreateHubClient,
    createUlanziLink = realCreateUlanziLink,
    createRenderer = realCreateRenderer,
    openContext = realOpenContext,
  } = deps;

  const cfg = resolveConfig(env, argv);
  const dbg = makeDebugLogger();
  let page = 0;
  let muted = false;

  const link = createUlanziLink({
    host: cfg.host, port: cfg.port, pluginUUID: cfg.pluginUUID,
    onAdd: (e) => dbg(`add ${JSON.stringify(e)}`),
    onRun: (e) => {
      dbg(`run ${JSON.stringify(e)}`);
      // param carrega o settings do botão; sessão configurada em param.id
      if (e.param && e.param.id) openContext(e.param.id, cfg);
    },
    onReady: () => renderer.render(hub.sessions(), { page, muted }),
  });

  const renderer = createRenderer({ link });

  const hub = createHubClient({
    url: cfg.hubWsUrl,
    onChange: (sessions) => renderer.render(sessions, { page, muted }),
  });

  hub.start();
  link.start();
  renderer.startPulse(() => ({ sessions: hub.sessions(), page, muted }));

  return { stop() { renderer.stopPulse(); hub.stop(); link.stop(); } };
}
