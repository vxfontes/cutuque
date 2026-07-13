// Default aponta para o hub no TAILSCALE (rede interna) — assim os agentes usam
// a CLI sem precisar setar env nenhuma. A mantenedora sobrescreve com
// CUTUQUE_HUB=127.0.0.1:8787 quando desenvolve local.
const DEFAULT_HUB = 'http://192.0.2.10:8787';

export function resolveConfig(env = {}) {
  let hubBaseUrl = env.CUTUQUE_HUB || env.CUTUQUE_DECK_HUB || DEFAULT_HUB;
  // Aceita "host:porta" além de URL completa: prefixa o esquema se faltar.
  if (!/^https?:\/\//i.test(hubBaseUrl)) hubBaseUrl = `http://${hubBaseUrl}`;
  return {
    hubBaseUrl,
    token: env.CUTUQUE_TOKEN || 'dev-token',
  };
}
