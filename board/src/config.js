export function resolveConfig(env = {}) {
  return {
    hubBaseUrl: env.CUTUQUE_HUB || env.CUTUQUE_DECK_HUB || 'http://127.0.0.1:8787',
    token: env.CUTUQUE_TOKEN || 'dev-token',
  };
}
