// Probe de descoberta: conecta no WebSocket do Ulanzi Studio (127.0.0.1:3906)
// como o plugin com.cutuque.deck e loga TODOS os eventos recebidos, com foco em
// `add`/`run` — que carregam o formato real de `key`/`actionid` de cada botão.
//
// Uso (com o deck plugado, o Studio aberto e o profile já pré-semeado com a
// action com.cutuque.deck.session nos slots):
//   node scripts/discover-keys.mjs
// Deixe rodar; o Studio manda um `add` por botão da nossa action ao carregar a
// página. Aperte cada botão para ver o `run` correspondente. Ctrl-C para sair.
//
// Objetivo: mapear slot ("coluna_linha") -> key real, para definir slotToKey.

import WS from 'ws';

const UUID = 'com.cutuque.deck';
const ws = new WS('ws://127.0.0.1:3906');

const seen = new Map(); // key -> { actionid, param }

ws.on('open', () => {
  console.log('[discover] conectado ao 3906; enviando handshake connected');
  ws.send(JSON.stringify({ code: 0, cmd: 'connected', uuid: UUID }));
  console.log('[discover] aguardando eventos add/run... (Ctrl-C para sair)\n');
});

ws.on('message', (raw) => {
  let d;
  try { d = JSON.parse(raw.toString()); } catch { return; }
  // ecoa tudo, resumido
  if (d.cmd === 'add' || d.cmd === 'run' || d.cmd === 'clear') {
    console.log(`[${d.cmd}] key=${JSON.stringify(d.key)} actionid=${JSON.stringify(d.actionid)} param=${JSON.stringify(d.param)}`);
    if (d.cmd === 'add' && d.key != null) seen.set(String(d.key), { actionid: d.actionid, param: d.param });
  } else {
    console.log(`[${d.cmd ?? '??'}] ${raw.toString().slice(0, 200)}`);
  }
});

ws.on('error', (e) => console.log('[discover] erro:', e.message));
ws.on('close', () => console.log('[discover] conexão fechada'));

// resumo ao sair
process.on('SIGINT', () => {
  console.log('\n[discover] ===== RESUMO (keys vistos em add) =====');
  for (const [key, info] of seen) console.log(`  key=${key}  actionid=${info.actionid}`);
  console.log(`[discover] total: ${seen.size} botões`);
  ws.close();
  process.exit(0);
});
