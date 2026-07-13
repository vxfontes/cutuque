export function resolveConfig(env = {}) {
  let hubBaseUrl = env.CUTUQUE_HUB || env.CUTUQUE_DECK_HUB || 'http://127.0.0.1:8787';
  // Aceita "host:porta" (como no protocolo) além de URL completa: prefixa o
  // esquema se faltar, senão o fetch falha com "Failed to parse URL".
  if (!/^https?:\/\//i.test(hubBaseUrl)) hubBaseUrl = `http://${hubBaseUrl}`;
  return {
    hubBaseUrl,
    token: env.CUTUQUE_TOKEN || 'dev-token',
  };
}
