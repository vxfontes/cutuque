// deck/src/main.js
import { resolveConfig } from './config.js';
import { createHubClient as realCreateHubClient } from './hubClient.js';
import { createUlanziLink as realCreateUlanziLink } from './ulanziLink.js';
import { createRenderer as realCreateRenderer } from './renderer.js';
import { openContext as realOpenContext } from './context.js';

export function startDeck({ env = process.env, argv = process.argv.slice(2), deps = {} } = {}) {
  const {
    createHubClient = realCreateHubClient,
    createUlanziLink = realCreateUlanziLink,
    createRenderer = realCreateRenderer,
    openContext = realOpenContext,
  } = deps;

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
