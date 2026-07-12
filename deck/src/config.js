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
    pluginUUID: 'com.cutuque.deck',
  };
}
