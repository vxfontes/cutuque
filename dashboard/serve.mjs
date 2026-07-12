// Servidor estático mínimo para o Cutuque Command Center (dashboard web).
// Serve index.html em http://127.0.0.1:<porta>. A página conecta no WS do hub
// (default 127.0.0.1:8787, token dev-token) — sobrescreva por query:
//   http://127.0.0.1:8420/?hub=192.0.2.10:8787&token=SEUTOKEN
// Uso:  node dashboard/serve.mjs   (porta padrão 8420, ou PORT=xxxx)
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const DIR = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT) || 8420;
const html = () => readFileSync(join(DIR, 'index.html'));

createServer((req, res) => {
  if (req.url === '/health') { res.writeHead(200); res.end('ok'); return; }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(html());
}).listen(PORT, '127.0.0.1', () => {
  console.log(`[cutuque-dashboard] http://127.0.0.1:${PORT}`);
});
