// Empacota a CLI num ÚNICO arquivo executável (dist/cutuque), sem dependências
// externas: hoista os imports node: (dedup), remove imports locais e o `export`,
// e concatena os módulos em ordem de dependência. O hub serve esse arquivo em
// GET /cutuque, e os agentes instalam via Tailscale (curl), sem precisar do repo.
import { readFileSync, writeFileSync, mkdirSync, chmodSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const ORDER = ['src/config.js', 'src/tmuxIdentity.js', 'src/agentType.js', 'src/hubClient.js', 'src/commands.js', 'bin/cutuque.js'];

const nodeImports = new Set();
let body = '';

for (const rel of ORDER) {
  let s = readFileSync(join(ROOT, rel), 'utf8');
  s = s.replace(/^#!.*\n/, '');                                   // remove shebang
  s = s.replace(/^\s*import\s+[^;]*from\s+['"]node:[^'"]+['"];?\s*$/gm, (m) => { nodeImports.add(m.trim()); return ''; });
  s = s.replace(/^\s*import\s+[^;]*from\s+['"]\.[^'"]*['"];?\s*$/gm, ''); // remove imports locais
  s = s.replace(/^export\s+/gm, '');                             // export function/const -> function/const
  body += `\n// ===== ${rel} =====\n${s.trim()}\n`;
}

const out = `#!/usr/bin/env node\n${[...nodeImports].join('\n')}\n${body}`;
mkdirSync(join(ROOT, 'dist'), { recursive: true });
const target = join(ROOT, 'dist', 'cutuque');
writeFileSync(target, out);
chmodSync(target, 0o755);
console.log(`[bundle] escrito ${target} (${out.length} bytes, ${nodeImports.size} imports node:)`);
