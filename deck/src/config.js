// deck/src/config.js
export function resolveConfig(env = {}, argv = []) {
  const token = env.CUTUQUE_TOKEN || 'dev-token';
  const hubBaseUrl = env.CUTUQUE_DECK_HUB || 'http://127.0.0.1:8787';
  const wsScheme = hubBaseUrl.startsWith('https') ? 'wss' : 'ws';
  const hubWsUrl = `${wsScheme}://${hubBaseUrl.replace(/^https?:\/\//, '')}/ws?token=${token}`;
  return {
    token,
    hubBaseUrl,
    hubWsUrl,
    host: argv[0] || '127.0.0.1',
    port: Number(argv[1]) || 3906,
    // O Ulanzi Studio exige UUID de plugin com exatamente 4 segmentos (como
    // com.uptime.monitor.deck); com 3 segmentos ele NÃO registra/lança o plugin.
    pluginUUID: 'com.cutuque.agents.deck',
  };
}
