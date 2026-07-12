// Monta uma versão AUTOCONTIDA do plugin em deck/dist/com.cutuque.deck.ulanziPlugin/.
//
// Por quê: quando o Ulanzi Studio instala o plugin, ele roda a pasta a partir de
//   ~/Library/Application Support/Ulanzi/UlanziDeck/Plugins/<plugin>/
// FORA de deck/. O import `../../src/main.js` e a resolução de `ws` quebram lá.
// Este build copia src/, assets/ e node_modules/ws PARA DENTRO da pasta do plugin
// e ajusta o entrypoint e o manifest, deixando o plugin 100% autossuficiente.
//
// Uso:  node scripts/build-plugin.mjs
// Saída: deck/dist/com.cutuque.deck.ulanziPlugin/ (gitignored)

import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { rmSync, mkdirSync, cpSync, writeFileSync, existsSync } from 'node:fs';

const DECK = join(dirname(fileURLToPath(import.meta.url)), '..');
const SRC_PLUGIN = join(DECK, 'com.cutuque.deck.ulanziPlugin');
const OUT = join(DECK, 'dist', 'com.cutuque.deck.ulanziPlugin');

function log(m) { console.log(`[build-plugin] ${m}`); }

// 1. Limpa e recria a saída
rmSync(join(DECK, 'dist'), { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });

// 2. manifest.json — ícones passam a ser relativos à raiz do plugin (assets/…)
const manifest = {
  UUID: 'com.cutuque.deck',
  Name: 'Cutuque Deck',
  Version: '0.1.0',
  Author: 'vxfontes',
  CodePath: 'app/index.js',
  Actions: [
    {
      UUID: 'com.cutuque.deck.session',
      Name: 'Cutuque Session',
      Tooltip: 'Um slot de sessão do Cutuque',
      Icon: 'assets/icons/idle.png',
      States: [{ Image: 'assets/icons/idle.png' }],
    },
  ],
};
writeFileSync(join(OUT, 'manifest.json'), JSON.stringify(manifest, null, 2));
log('manifest.json escrito (ícones self-contained)');

// 3. app/index.js — entrypoint aponta para a cópia interna de src/
mkdirSync(join(OUT, 'app'), { recursive: true });
writeFileSync(
  join(OUT, 'app', 'index.js'),
  [
    '// Entrypoint lançado pelo Ulanzi Studio: node app/index.js <host> <port> <lang>',
    "import { startDeck } from '../src/main.js';",
    'startDeck();',
    '',
  ].join('\n'),
);
log('app/index.js escrito (import ../src/main.js)');

// 4. Copia src/ e assets/ pra dentro do plugin
cpSync(join(DECK, 'src'), join(OUT, 'src'), { recursive: true });
cpSync(join(DECK, 'assets'), join(OUT, 'assets'), { recursive: true });
log('src/ e assets/ copiados');

// 5. Empacota ws em node_modules/ws (resolução local a partir de src/)
const wsSrc = join(DECK, 'node_modules', 'ws');
if (!existsSync(wsSrc)) {
  console.error('[build-plugin] ERRO: deck/node_modules/ws não existe — rode `npm install` em deck/ antes.');
  process.exit(1);
}
mkdirSync(join(OUT, 'node_modules'), { recursive: true });
cpSync(wsSrc, join(OUT, 'node_modules', 'ws'), { recursive: true });
log('node_modules/ws empacotado');

// 6. Verificação: ícones existem, entrypoint e manifest no lugar
const mustExist = [
  'manifest.json', 'app/index.js', 'src/main.js', 'src/colors.js',
  'assets/icons/idle.png', 'assets/icons/needs_you.png', 'node_modules/ws/package.json',
];
const missing = mustExist.filter((f) => !existsSync(join(OUT, f)));
if (missing.length) {
  console.error('[build-plugin] ERRO: faltando na saída:', missing);
  process.exit(1);
}
log(`OK — plugin autocontido em ${OUT}`);
