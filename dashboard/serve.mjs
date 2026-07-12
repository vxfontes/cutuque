// Cutuque Command Center — servidor + PROXY WebSocket same-origin para o hub.
//
// Por que um proxy: o hub usa websocket.Accept com checagem de origin e RECUSA
// (403) conexões WS de navegador cross-origin (os apps nativos iOS/Watch não
// mandam header Origin, então passam). Em vez de mexer no hub (restrição
// aditiva), o dashboard serve a página E encaminha ws://<este-host>/ws -> hub,
// injetando o token e sem mandar Origin. O browser fala só com este servidor
// (same-origin), então nada é bloqueado.
//
// Uso:  node dashboard/serve.mjs            (porta 8420; hub 127.0.0.1:8787)
//   PORT=9000 CUTUQUE_HUB=192.0.2.10:8787 CUTUQUE_TOKEN=xxx node dashboard/serve.mjs
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { WebSocketServer, WebSocket } from 'ws';

const DIR = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT) || 8420;
const HUB = process.env.CUTUQUE_HUB || '127.0.0.1:8787';
const TOKEN = process.env.CUTUQUE_TOKEN || 'dev-token';
const HUB_WS = `ws://${HUB}/ws?token=${encodeURIComponent(TOKEN)}`;

const server = createServer((req, res) => {
  if (req.url === '/health') { res.writeHead(200); res.end('ok'); return; }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(readFileSync(join(DIR, 'index.html')));
});

// Proxy WS: cada cliente do browser abre uma conexão upstream para o hub.
const wss = new WebSocketServer({ server, path: '/ws' });
wss.on('connection', (client) => {
  const upstream = new WebSocket(HUB_WS); // sem header Origin -> hub aceita
  let open = false;
  upstream.on('open', () => { open = true; });
  upstream.on('message', (d) => { if (client.readyState === 1) client.send(d.toString()); });
  upstream.on('close', () => { try { client.close(); } catch { /* noop */ } });
  upstream.on('error', () => { try { client.close(); } catch { /* noop */ } });
  // O dashboard é só-leitura; ainda assim repassamos o que o browser mandar.
  client.on('message', (d) => { if (open && upstream.readyState === 1) upstream.send(d.toString()); });
  client.on('close', () => { try { upstream.close(); } catch { /* noop */ } });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[cutuque-dashboard] http://127.0.0.1:${PORT}  (proxy WS -> ${HUB})`);
});
