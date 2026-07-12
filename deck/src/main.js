// deck/src/main.js
import { resolveConfig } from './config.js';
import { createHubClient } from './hubClient.js';
import { createUlanziLink } from './ulanziLink.js';
import { createRenderer } from './renderer.js';
import { openContext } from './context.js';
import { SESSION_SLOTS } from './board.js';

export function startDeck({ env = process.env, argv = process.argv.slice(2) } = {}) {
  const cfg = resolveConfig(env, argv);
  let page = 0;
  let muted = false;

  const link = createUlanziLink({
    host: cfg.host, port: cfg.port, pluginUUID: cfg.pluginUUID,
    onRun: ({ param }) => {
      // param carrega o settings do botão; sessão configurada em param.id
      if (param && param.id) openContext(param.id, cfg);
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
