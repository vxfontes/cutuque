# Cutuque Deck Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Um plugin Ulanzi fino que espelha as sessões do hub Cutuque no Stream Deck (cor por estado, ordem por prioridade) e, ao apertar uma sessão, abre o contexto dela na tela do Mac.

**Architecture:** Padrão "hub cérebro + apps finos". O plugin roda localmente (lançado pelo Ulanzi Studio), conecta em dois WebSockets — o do Ulanzi Studio (`127.0.0.1:3906`, protocolo de plugin) e o do hub Cutuque (`/ws`, só-leitura) — e traduz um no outro. Toda a lógica de mapeamento é composta de funções puras testáveis; o I/O fica em módulos finos isolados.

**Tech Stack:** Node.js (ESM), pacote `ws` (WebSocket, já usado pelos plugins Ulanzi), `node:test` + `node:assert` (test runner nativo, zero toolchain novo). Sem TypeScript.

## Global Constraints

- **Estritamente aditivo:** não modificar `app/` (iOS/watchOS) nem alterar comportamento do `hub/`. O deck vive isolado em `deck/`. Zero mudança nos contratos WS/REST existentes.
- **Só-leitura no hub:** o deck consome `GET /ws`, `GET /sessions/{id}/output`. Não chama nenhum endpoint que muta estado (nada de approve/deny/launch no MVP).
- **Nunca às cegas:** o deck jamais aprova/nega; apertar só traz o contexto pra tela.
- **Hub:** base dev `http://127.0.0.1:8787`, prod `http://192.0.2.10:8787`. Auth Bearer (`CUTUQUE_TOKEN`; dev default `dev-token`). WS autentica por `?token=<token>`.
- **Estados:** exatamente `running | needs_you | done | idle | error` (strings do hub, `session.State`).
- **Protocolo Ulanzi (3906):** ao abrir o WS, enviar `{code:0,cmd:"connected",uuid:"<pluginUUID>"}`. Eventos recebidos: `add`, `run`, `clear`, `paramfromapp`. Para pintar um botão, enviar `{cmd:"state",uuid,key,actionid,param:{statelist:[{uuid,key,actionid,type:2,path,textData,showtext}]}}` (type 2 = ícone por caminho de arquivo). O handle de um botão (`key`+`actionid`) vem nos eventos `add`.
- **Hardware:** grid 5×3 com 13 teclas úteis; a linha inferior só tem colunas 1–3 (`3_2`/`4_2` não existem).

## Shared Types (contratos entre tarefas)

```js
// Session — objeto exatamente como o hub serializa (hub/internal/session/session.go).
// { id, machine, agent, title, state, created_at, updated_at,
//   pending_prompt?, cwd?, model?, external?, pane?, pending_questions? }

// SlotName — nome de slot do keypad no formato "coluna_linha" (0-indexado).
//   Sessões: "0_0","1_0","2_0","3_0","4_0","0_1","1_1","2_1"   (8 slots)
//   Paginação: "3_1" (◀ prev), "4_1" (▶ next)
//   Globais: "0_2" (🖥 máquina), "1_2" (🔕 mute), "2_2" (⚙ menu)

// BoardSlot — { slot: SlotName, kind: "session"|"prev"|"next"|"machine"|"mute"|"menu",
//               session?: Session, iconPath: string, title: string }
```

## File Structure

```
deck/
  package.json                       # ESM, deps: ws; scripts: test
  README.md                          # como instalar/rodar (curto)
  src/
    config.js         # resolve hub base URL, token, pluginUUID (env + arquivo local)
    priority.js       # ordem por prioridade + paginação (puro)
    colors.js         # estado -> cor/ícone (puro)
    board.js          # sessões -> BoardSlot[] (puro; usa priority+colors)
    hubClient.js      # WS do hub: snapshot/updated/removed -> mapa de sessões + reconexão
    ulanziLink.js     # WS 3906: handshake, add/run/clear, sendState
    renderer.js       # BoardSlot[] -> comandos state; timer de pulso do needs_you
    context.js        # ao apertar sessão: busca output no hub e abre na tela do Mac
    main.js           # fiação: entrypoint lançado pelo Ulanzi Studio
  test/
    priority.test.js
    colors.test.js
    board.test.js
    hubClient.test.js
    ulanziLink.test.js
    renderer.test.js
    context.test.js
  assets/icons/                      # PNGs coloridos por estado (gerados)
  scripts/
    gen-icons.mjs                    # gera os PNGs de estado (roda 1x)
    setup-profile.mjs                # pré-semeia o profile "Cutuque" no Ulanzi
  com.cutuque.deck.ulanziPlugin/     # pacote do plugin instalável
    manifest.json                    # declara plugin + action "Cutuque Session"
    app/index.js                     # re-exporta ../../src/main.js (entry do Studio)
    node_modules/ws/                 # ws empacotado (o Studio roda com Node próprio)
```

---

### Task 1: Scaffold do projeto + módulo de config

**Files:**
- Create: `deck/package.json`
- Create: `deck/src/config.js`
- Test: `deck/test/config.test.js`

**Interfaces:**
- Consumes: nada.
- Produces: `resolveConfig(env, argv) -> { hubBaseUrl, hubWsUrl, token, pluginUUID, host, port }`
  - `env`: objeto tipo `process.env`. `argv`: array tipo `process.argv.slice(2)` = `[host, port, lang]` que o Studio passa.
  - Regras: `token = env.CUTUQUE_TOKEN || "dev-token"`. `hubBaseUrl = env.CUTUQUE_DECK_HUB || "http://127.0.0.1:8787"`. `hubWsUrl` = base com esquema `ws`/`wss` + `/ws?token=<token>`. `host = argv[0] || "127.0.0.1"`, `port = Number(argv[1]) || 3906`. `pluginUUID = "com.cutuque.deck"`.

- [ ] **Step 1: Criar `deck/package.json`**

```json
{
  "name": "cutuque-deck",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "Cliente-mesa do Cutuque para Stream Deck Ulanzi (aditivo, só-leitura).",
  "scripts": {
    "test": "node --test"
  },
  "dependencies": {
    "ws": "^8.18.0"
  }
}
```

- [ ] **Step 2: Escrever o teste que falha**

```js
// deck/test/config.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveConfig } from '../src/config.js';

test('usa defaults de dev quando env vazio', () => {
  const c = resolveConfig({}, []);
  assert.equal(c.token, 'dev-token');
  assert.equal(c.hubBaseUrl, 'http://127.0.0.1:8787');
  assert.equal(c.hubWsUrl, 'ws://127.0.0.1:8787/ws?token=dev-token');
  assert.equal(c.host, '127.0.0.1');
  assert.equal(c.port, 3906);
  assert.equal(c.pluginUUID, 'com.cutuque.deck');
});

test('respeita env e argv do Studio', () => {
  const c = resolveConfig(
    { CUTUQUE_TOKEN: 'abc', CUTUQUE_DECK_HUB: 'https://192.0.2.10:8787' },
    ['127.0.0.1', '3906', 'pt-PT']
  );
  assert.equal(c.token, 'abc');
  assert.equal(c.hubWsUrl, 'wss://192.0.2.10:8787/ws?token=abc');
});
```

- [ ] **Step 3: Rodar e ver falhar**

Run: `cd deck && node --test test/config.test.js`
Expected: FAIL (`Cannot find module '../src/config.js'`)

- [ ] **Step 4: Implementar `deck/src/config.js`**

```js
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
```

- [ ] **Step 5: Rodar e ver passar**

Run: `cd deck && node --test test/config.test.js`
Expected: PASS (2 tests)

- [ ] **Step 6: Instalar deps e commitar**

```bash
cd deck && npm install
git add deck/package.json deck/package-lock.json deck/src/config.js deck/test/config.test.js
git commit -m "feat(deck): scaffold + módulo de config"
```

---

### Task 2: Ordenação por prioridade + paginação (puro)

**Files:**
- Create: `deck/src/priority.js`
- Test: `deck/test/priority.test.js`

**Interfaces:**
- Consumes: `Session[]`.
- Produces:
  - `PRIORITY = { needs_you:0, error:1, running:2, done:3, idle:4 }`
  - `sortByPriority(sessions) -> Session[]` — ordena por `PRIORITY[state]` asc; empate por `updated_at` desc (mais recente primeiro). Não muta a entrada.
  - `paginate(sortedSessions, page, perPage=8) -> { items: Session[], page, pageCount, hasPrev, hasNext }` — `page` 0-indexado, clampado a `[0, pageCount-1]`.

- [ ] **Step 1: Escrever o teste que falha**

```js
// deck/test/priority.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sortByPriority, paginate } from '../src/priority.js';

const S = (id, state, updated) => ({ id, state, updated_at: updated });

test('ordena needs_you > error > running > done > idle', () => {
  const out = sortByPriority([
    S('a', 'idle', '2026-01-01T00:00:00Z'),
    S('b', 'needs_you', '2026-01-01T00:00:00Z'),
    S('c', 'running', '2026-01-01T00:00:00Z'),
    S('d', 'error', '2026-01-01T00:00:00Z'),
    S('e', 'done', '2026-01-01T00:00:00Z'),
  ]);
  assert.deepEqual(out.map((s) => s.id), ['b', 'd', 'c', 'e', 'a']);
});

test('empate no estado: mais recente primeiro', () => {
  const out = sortByPriority([
    S('old', 'running', '2026-01-01T00:00:00Z'),
    S('new', 'running', '2026-06-01T00:00:00Z'),
  ]);
  assert.deepEqual(out.map((s) => s.id), ['new', 'old']);
});

test('não muta a entrada', () => {
  const input = [S('a', 'idle', '2026-01-01T00:00:00Z'), S('b', 'needs_you', '2026-01-01T00:00:00Z')];
  const copy = [...input];
  sortByPriority(input);
  assert.deepEqual(input, copy);
});

test('paginate: 10 itens, 8 por página', () => {
  const items = Array.from({ length: 10 }, (_, i) => S(String(i), 'idle', '2026-01-01T00:00:00Z'));
  const p0 = paginate(items, 0);
  assert.equal(p0.items.length, 8);
  assert.equal(p0.pageCount, 2);
  assert.equal(p0.hasPrev, false);
  assert.equal(p0.hasNext, true);
  const p1 = paginate(items, 1);
  assert.equal(p1.items.length, 2);
  assert.equal(p1.hasNext, false);
  assert.equal(p1.hasPrev, true);
});

test('paginate: page fora do range é clampado', () => {
  const items = [S('a', 'idle', '2026-01-01T00:00:00Z')];
  assert.equal(paginate(items, 5).page, 0);
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd deck && node --test test/priority.test.js`
Expected: FAIL (`Cannot find module '../src/priority.js'`)

- [ ] **Step 3: Implementar `deck/src/priority.js`**

```js
// deck/src/priority.js
export const PRIORITY = { needs_you: 0, error: 1, running: 2, done: 3, idle: 4 };

export function sortByPriority(sessions) {
  return [...sessions].sort((a, b) => {
    const pa = PRIORITY[a.state] ?? 99;
    const pb = PRIORITY[b.state] ?? 99;
    if (pa !== pb) return pa - pb;
    // empate: mais recente primeiro (updated_at desc)
    return String(b.updated_at).localeCompare(String(a.updated_at));
  });
}

export function paginate(sortedSessions, page, perPage = 8) {
  const pageCount = Math.max(1, Math.ceil(sortedSessions.length / perPage));
  const clamped = Math.min(Math.max(0, page | 0), pageCount - 1);
  const start = clamped * perPage;
  return {
    items: sortedSessions.slice(start, start + perPage),
    page: clamped,
    pageCount,
    hasPrev: clamped > 0,
    hasNext: clamped < pageCount - 1,
  };
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd deck && node --test test/priority.test.js`
Expected: PASS (5 tests)

- [ ] **Step 5: Commitar**

```bash
git add deck/src/priority.js deck/test/priority.test.js
git commit -m "feat(deck): ordenação por prioridade + paginação"
```

---

### Task 3: Mapa de cores/ícones por estado (puro)

**Files:**
- Create: `deck/src/colors.js`
- Test: `deck/test/colors.test.js`

**Interfaces:**
- Consumes: `state` (string).
- Produces:
  - `STATE_COLORS = { running, needs_you, done, error, idle }` → hex string cada.
  - `iconPathForState(state, { pulseOn=false } = {}) -> string` — caminho absoluto do PNG do estado, dentro de `assets/icons/`. Para `needs_you`, alterna entre `needs_you.png` (pulseOn=false) e `needs_you_dim.png` (pulseOn=true). Usa `import.meta.url` p/ resolver o caminho de `assets/icons/` relativo ao módulo.

- [ ] **Step 1: Escrever o teste que falha**

```js
// deck/test/colors.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { STATE_COLORS, iconPathForState } from '../src/colors.js';

test('cada estado tem uma cor hex', () => {
  for (const s of ['running', 'needs_you', 'done', 'error', 'idle']) {
    assert.match(STATE_COLORS[s], /^#[0-9A-Fa-f]{6}$/);
  }
});

test('iconPathForState aponta para assets/icons e o estado', () => {
  const p = iconPathForState('running');
  assert.ok(p.endsWith('assets/icons/running.png'), p);
});

test('needs_you alterna com pulseOn', () => {
  assert.ok(iconPathForState('needs_you', { pulseOn: false }).endsWith('needs_you.png'));
  assert.ok(iconPathForState('needs_you', { pulseOn: true }).endsWith('needs_you_dim.png'));
});

test('estado desconhecido cai em idle', () => {
  assert.ok(iconPathForState('sei_la').endsWith('idle.png'));
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd deck && node --test test/colors.test.js`
Expected: FAIL (`Cannot find module '../src/colors.js'`)

- [ ] **Step 3: Implementar `deck/src/colors.js`**

```js
// deck/src/colors.js
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ICONS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'assets', 'icons');

export const STATE_COLORS = {
  running: '#2D7FF9',
  needs_you: '#F5A623',
  done: '#3DC46A',
  error: '#E5484D',
  idle: '#6B7280',
};

export function iconPathForState(state, { pulseOn = false } = {}) {
  const known = STATE_COLORS[state] ? state : 'idle';
  if (known === 'needs_you' && pulseOn) return join(ICONS_DIR, 'needs_you_dim.png');
  return join(ICONS_DIR, `${known}.png`);
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd deck && node --test test/colors.test.js`
Expected: PASS (4 tests)

- [ ] **Step 5: Commitar**

```bash
git add deck/src/colors.js deck/test/colors.test.js
git commit -m "feat(deck): cores e ícones por estado"
```

---

### Task 4: Board — sessões → BoardSlot[] (puro)

**Files:**
- Create: `deck/src/board.js`
- Test: `deck/test/board.test.js`

**Interfaces:**
- Consumes: `sortByPriority`, `paginate` (Task 2), `iconPathForState` (Task 3).
- Produces:
  - `SESSION_SLOTS = ["0_0","1_0","2_0","3_0","4_0","0_1","1_1","2_1"]`
  - `PREV_SLOT="3_1"`, `NEXT_SLOT="4_1"`, `MACHINE_SLOT="0_2"`, `MUTE_SLOT="1_2"`, `MENU_SLOT="2_2"`
  - `buildBoard(sessions, { page=0, pulseOn=false, muted=false } = {}) -> BoardSlot[]` — ordena, pagina (8/pág), mapeia cada sessão a um slot de sessão com `iconPath` e `title` (o `title` da sessão ou `machine`), adiciona slots de paginação (só quando `hasPrev`/`hasNext`), e os 3 globais. Slots de sessão sem sessão na página recebem `kind:"session"` com `session:null` e ícone vazio (apaga o botão). Para `needs_you`, aplica `pulseOn` salvo se `muted`.

- [ ] **Step 1: Escrever o teste que falha**

```js
// deck/test/board.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildBoard, SESSION_SLOTS, NEXT_SLOT, MUTE_SLOT } from '../src/board.js';

const S = (id, state) => ({ id, state, title: id, machine: 'mac', updated_at: '2026-01-01T00:00:00Z' });

test('mapeia sessões aos 8 slots na ordem de prioridade', () => {
  const board = buildBoard([S('a', 'idle'), S('b', 'needs_you')]);
  const slotA = board.find((x) => x.slot === '0_0'); // needs_you sobe pro topo
  assert.equal(slotA.session.id, 'b');
  assert.equal(slotA.kind, 'session');
});

test('mais de 8 sessões liga o botão next', () => {
  const many = Array.from({ length: 10 }, (_, i) => S(String(i), 'running'));
  const board = buildBoard(many, { page: 0 });
  const next = board.find((x) => x.slot === NEXT_SLOT);
  assert.equal(next.kind, 'next');
});

test('tem sempre os 3 globais', () => {
  const board = buildBoard([]);
  assert.ok(board.find((x) => x.slot === MUTE_SLOT && x.kind === 'mute'));
});

test('muted desliga o pulso do needs_you', () => {
  const board = buildBoard([S('b', 'needs_you')], { pulseOn: true, muted: true });
  const slot = board.find((x) => x.session?.id === 'b');
  assert.ok(slot.iconPath.endsWith('needs_you.png')); // não o _dim
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd deck && node --test test/board.test.js`
Expected: FAIL (`Cannot find module '../src/board.js'`)

- [ ] **Step 3: Implementar `deck/src/board.js`**

```js
// deck/src/board.js
import { sortByPriority, paginate } from './priority.js';
import { iconPathForState } from './colors.js';

export const SESSION_SLOTS = ['0_0', '1_0', '2_0', '3_0', '4_0', '0_1', '1_1', '2_1'];
export const PREV_SLOT = '3_1';
export const NEXT_SLOT = '4_1';
export const MACHINE_SLOT = '0_2';
export const MUTE_SLOT = '1_2';
export const MENU_SLOT = '2_2';

export function buildBoard(sessions, { page = 0, pulseOn = false, muted = false } = {}) {
  const sorted = sortByPriority(sessions);
  const pg = paginate(sorted, page, SESSION_SLOTS.length);
  const slots = [];

  SESSION_SLOTS.forEach((slot, i) => {
    const session = pg.items[i] || null;
    if (!session) {
      slots.push({ slot, kind: 'session', session: null, iconPath: '', title: '' });
      return;
    }
    const pulse = session.state === 'needs_you' && pulseOn && !muted;
    slots.push({
      slot,
      kind: 'session',
      session,
      iconPath: iconPathForState(session.state, { pulseOn: pulse }),
      title: session.title || session.machine || session.id,
    });
  });

  if (pg.hasPrev) slots.push({ slot: PREV_SLOT, kind: 'prev', iconPath: '', title: '◀' });
  if (pg.hasNext) slots.push({ slot: NEXT_SLOT, kind: 'next', iconPath: '', title: '▶' });

  slots.push({ slot: MACHINE_SLOT, kind: 'machine', iconPath: '', title: '🖥' });
  slots.push({ slot: MUTE_SLOT, kind: 'mute', iconPath: '', title: muted ? '🔕' : '🔔' });
  slots.push({ slot: MENU_SLOT, kind: 'menu', iconPath: '', title: '⚙' });

  return slots;
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd deck && node --test test/board.test.js`
Expected: PASS (4 tests)

- [ ] **Step 5: Commitar**

```bash
git add deck/src/board.js deck/test/board.test.js
git commit -m "feat(deck): board sessões->slots (puro)"
```

---

### Task 5: Hub client — WS só-leitura com reconexão

**Files:**
- Create: `deck/src/hubClient.js`
- Test: `deck/test/hubClient.test.js`

**Interfaces:**
- Consumes: `ws` (npm). Contrato do hub: WS emite `{type:"snapshot",sessions:[]}`, `{type:"session_updated",session}`, `{type:"session_removed",session_id}`, `{type:"output_chunk",...}` (ignorado aqui).
- Produces: `createHubClient({ url, WebSocketImpl=WebSocket, onChange }) -> { start(), stop(), sessions() }`
  - Mantém um `Map<id, Session>`. `snapshot` substitui tudo; `session_updated` faz upsert; `session_removed` remove. Após cada mudança chama `onChange(sessionsArray)`.
  - Reconexão: ao fechar/errar, reconecta após 2s (backoff simples fixo). `stop()` cancela.
  - `WebSocketImpl` injetável para teste.

- [ ] **Step 1: Escrever o teste que falha (usando um fake WS em memória)**

```js
// deck/test/hubClient.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { createHubClient } from '../src/hubClient.js';

// Fake WS: dispara open no próximo tick; expõe emitMessage() pro teste.
class FakeWS extends EventEmitter {
  constructor() {
    super();
    FakeWS.last = this;
    queueMicrotask(() => this.emit('open'));
  }
  emitMessage(obj) { this.emit('message', Buffer.from(JSON.stringify(obj))); }
  close() { this.emit('close'); }
}

test('aplica snapshot e updated e removed', async () => {
  const changes = [];
  const client = createHubClient({
    url: 'ws://x/ws',
    WebSocketImpl: FakeWS,
    onChange: (s) => changes.push(s),
  });
  client.start();
  await new Promise((r) => setTimeout(r, 5));

  FakeWS.last.emitMessage({ type: 'snapshot', sessions: [{ id: 'a', state: 'idle', updated_at: '1' }] });
  assert.equal(client.sessions().length, 1);

  FakeWS.last.emitMessage({ type: 'session_updated', session: { id: 'b', state: 'running', updated_at: '2' } });
  assert.equal(client.sessions().length, 2);

  FakeWS.last.emitMessage({ type: 'session_removed', session_id: 'a' });
  assert.deepEqual(client.sessions().map((s) => s.id), ['b']);

  client.stop();
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd deck && node --test test/hubClient.test.js`
Expected: FAIL (`Cannot find module '../src/hubClient.js'`)

- [ ] **Step 3: Implementar `deck/src/hubClient.js`**

```js
// deck/src/hubClient.js
import WS from 'ws';

export function createHubClient({ url, WebSocketImpl = WS, onChange = () => {} }) {
  const sessions = new Map();
  let ws = null;
  let stopped = false;
  let retry = null;

  function emit() {
    onChange([...sessions.values()]);
  }

  function handle(raw) {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    switch (msg.type) {
      case 'snapshot':
        sessions.clear();
        for (const s of msg.sessions || []) sessions.set(s.id, s);
        emit();
        break;
      case 'session_updated':
        if (msg.session) { sessions.set(msg.session.id, msg.session); emit(); }
        break;
      case 'session_removed':
        if (sessions.delete(msg.session_id)) emit();
        break;
      default:
        break; // output_chunk etc. ignorados
    }
  }

  function connect() {
    if (stopped) return;
    ws = new WebSocketImpl(url);
    ws.on('message', handle);
    ws.on('close', scheduleReconnect);
    ws.on('error', () => {}); // 'close' cuida da reconexão
  }

  function scheduleReconnect() {
    if (stopped) return;
    retry = setTimeout(connect, 2000);
  }

  return {
    start() { stopped = false; connect(); },
    stop() { stopped = true; clearTimeout(retry); if (ws) try { ws.close(); } catch {} },
    sessions() { return [...sessions.values()]; },
  };
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd deck && node --test test/hubClient.test.js`
Expected: PASS (1 test)

- [ ] **Step 5: Commitar**

```bash
git add deck/src/hubClient.js deck/test/hubClient.test.js
git commit -m "feat(deck): hub client WS só-leitura com reconexão"
```

---

### Task 6: Ulanzi link — WS 3906 (handshake, add/run/clear, sendState)

**Files:**
- Create: `deck/src/ulanziLink.js`
- Test: `deck/test/ulanziLink.test.js`

**Interfaces:**
- Consumes: `ws` (npm).
- Produces: `createUlanziLink({ host, port, pluginUUID, WebSocketImpl=WS, onRun, onReady }) -> { start(), stop(), sendState(slotHandle, iconPath, title), handles() }`
  - No `open`: envia `{code:0,cmd:"connected",uuid:pluginUUID}`.
  - Em `add`: registra o handle do botão por `key` — `handles().set(key, { key, actionid })` — para poder pintar depois. Chama `onReady()`.
  - Em `run`: extrai `{key, actionid, param}` e chama `onRun({ key, actionid, param })` (param carrega o settings do botão, incl. o `id` da sessão configurado).
  - Em `clear`: remove os handles listados.
  - `sendState({key, actionid}, iconPath, title)`: envia
    `{cmd:"state",uuid:pluginUUID,key,actionid,param:{statelist:[{uuid:pluginUUID,key,actionid,type:2,path:iconPath,textData:title||"",showtext:!!title}]}}`.
  - **Nota de descoberta:** o formato exato de `key`/`actionid` nos eventos `add`/`run` deve ser confirmado logando os eventos reais na Task 9 (integração). O módulo trata `key`/`actionid` como opacos.

- [ ] **Step 1: Escrever o teste que falha**

```js
// deck/test/ulanziLink.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { createUlanziLink } from '../src/ulanziLink.js';

class FakeWS extends EventEmitter {
  constructor() { super(); FakeWS.last = this; this.sent = []; queueMicrotask(() => this.emit('open')); }
  send(str) { this.sent.push(JSON.parse(str)); }
  emitMessage(obj) { this.emit('message', Buffer.from(JSON.stringify(obj))); }
  close() { this.emit('close'); }
}

test('handshake connected no open', async () => {
  const link = createUlanziLink({ host: '127.0.0.1', port: 3906, pluginUUID: 'com.cutuque.deck', WebSocketImpl: FakeWS });
  link.start();
  await new Promise((r) => setTimeout(r, 5));
  assert.deepEqual(FakeWS.last.sent[0], { code: 0, cmd: 'connected', uuid: 'com.cutuque.deck' });
  link.stop();
});

test('add registra handle; run dispara onRun; sendState monta statelist', async () => {
  const runs = [];
  const link = createUlanziLink({
    host: '127.0.0.1', port: 3906, pluginUUID: 'com.cutuque.deck',
    WebSocketImpl: FakeWS, onRun: (e) => runs.push(e),
  });
  link.start();
  await new Promise((r) => setTimeout(r, 5));

  FakeWS.last.emitMessage({ cmd: 'add', key: 'k1', actionid: 'a1' });
  assert.ok(link.handles().get('k1'));

  FakeWS.last.emitMessage({ cmd: 'run', key: 'k1', actionid: 'a1', param: { id: 'sess-1' } });
  assert.deepEqual(runs[0], { key: 'k1', actionid: 'a1', param: { id: 'sess-1' } });

  link.sendState({ key: 'k1', actionid: 'a1' }, '/x/running.png', 'mac');
  const stateMsg = FakeWS.last.sent.find((m) => m.cmd === 'state');
  assert.equal(stateMsg.param.statelist[0].path, '/x/running.png');
  assert.equal(stateMsg.param.statelist[0].type, 2);
  link.stop();
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd deck && node --test test/ulanziLink.test.js`
Expected: FAIL (`Cannot find module '../src/ulanziLink.js'`)

- [ ] **Step 3: Implementar `deck/src/ulanziLink.js`**

```js
// deck/src/ulanziLink.js
import WS from 'ws';

export function createUlanziLink({ host, port, pluginUUID, WebSocketImpl = WS, onRun = () => {}, onReady = () => {} }) {
  const handles = new Map(); // key -> { key, actionid }
  let ws = null;
  let stopped = false;
  let retry = null;

  function handle(raw) {
    let d;
    try { d = JSON.parse(raw.toString()); } catch { return; }
    switch (d.cmd) {
      case 'add':
        if (d.key) { handles.set(d.key, { key: d.key, actionid: d.actionid }); onReady(); }
        break;
      case 'run':
        onRun({ key: d.key, actionid: d.actionid, param: d.param });
        break;
      case 'clear': {
        const list = Array.isArray(d.param) ? d.param : [];
        for (const p of list) handles.delete(p.key);
        break;
      }
      default:
        break;
    }
  }

  function connect() {
    if (stopped) return;
    ws = new WebSocketImpl(`ws://${host}:${port}`);
    ws.on('open', () => ws.send(JSON.stringify({ code: 0, cmd: 'connected', uuid: pluginUUID })));
    ws.on('message', handle);
    ws.on('close', () => { if (!stopped) retry = setTimeout(connect, 2000); });
    ws.on('error', () => {});
  }

  return {
    start() { stopped = false; connect(); },
    stop() { stopped = true; clearTimeout(retry); if (ws) try { ws.close(); } catch {} },
    handles() { return handles; },
    sendState({ key, actionid }, iconPath, title) {
      if (!ws) return;
      ws.send(JSON.stringify({
        cmd: 'state', uuid: pluginUUID, key, actionid,
        param: { statelist: [{ uuid: pluginUUID, key, actionid, type: 2, path: iconPath, textData: title || '', showtext: !!title }] },
      }));
    },
  };
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd deck && node --test test/ulanziLink.test.js`
Expected: PASS (2 tests)

- [ ] **Step 5: Commitar**

```bash
git add deck/src/ulanziLink.js deck/test/ulanziLink.test.js
git commit -m "feat(deck): ulanzi link (3906) handshake/add/run/state"
```

---

### Task 7: Context opener — apertar sessão abre o output no Mac

**Files:**
- Create: `deck/src/context.js`
- Test: `deck/test/context.test.js`

**Interfaces:**
- Consumes: contrato REST `GET /sessions/{id}/output` → `{chunks:[{...,data|text}]}`. Bearer token.
- Produces: `openContext(sessionId, { hubBaseUrl, token, fetchImpl=fetch, spawnImpl } ) -> Promise<void>`
  - Faz `GET ${hubBaseUrl}/sessions/${sessionId}/output` com header `Authorization: Bearer ${token}`.
  - Concatena o texto dos chunks, grava em `os.tmpdir()/cutuque-deck-<id>.txt`, e abre na tela do Mac com `spawnImpl('open', ['-a', 'TextEdit', file])` (forma concreta escolhida: abrir o output num TextEdit — simples, nativo, sem depender de terminal). `spawnImpl` injetável p/ teste.
  - Em erro de rede/404, não lança: loga em stderr e retorna (o deck nunca deve crashar por causa de um aperto).

- [ ] **Step 1: Escrever o teste que falha**

```js
// deck/test/context.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openContext } from '../src/context.js';

test('busca output com Bearer e abre no Mac', async () => {
  let seenUrl, seenAuth, spawned;
  const fetchImpl = async (url, opts) => {
    seenUrl = url; seenAuth = opts.headers.Authorization;
    return { ok: true, json: async () => ({ chunks: [{ data: 'linha 1\n' }, { data: 'linha 2\n' }] }) };
  };
  const spawnImpl = (cmd, args) => { spawned = { cmd, args }; };

  await openContext('sess-1', { hubBaseUrl: 'http://h:8787', token: 'tok', fetchImpl, spawnImpl });

  assert.equal(seenUrl, 'http://h:8787/sessions/sess-1/output');
  assert.equal(seenAuth, 'Bearer tok');
  assert.equal(spawned.cmd, 'open');
  assert.ok(spawned.args.join(' ').includes('cutuque-deck-sess-1.txt'));
});

test('erro de rede não lança', async () => {
  const fetchImpl = async () => { throw new Error('boom'); };
  await assert.doesNotReject(openContext('x', { hubBaseUrl: 'http://h', token: 't', fetchImpl, spawnImpl: () => {} }));
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd deck && node --test test/context.test.js`
Expected: FAIL (`Cannot find module '../src/context.js'`)

- [ ] **Step 3: Implementar `deck/src/context.js`**

```js
// deck/src/context.js
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

export async function openContext(sessionId, { hubBaseUrl, token, fetchImpl = fetch, spawnImpl }) {
  const doSpawn = spawnImpl || ((cmd, args) => spawn(cmd, args, { detached: true, stdio: 'ignore' }).unref());
  try {
    const res = await fetchImpl(`${hubBaseUrl}/sessions/${sessionId}/output`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!res.ok) { process.stderr.write(`[deck] output ${sessionId}: HTTP ${res.status}\n`); return; }
    const body = await res.json();
    const text = (body.chunks || []).map((c) => c.data ?? c.text ?? '').join('');
    const file = join(tmpdir(), `cutuque-deck-${sessionId}.txt`);
    writeFileSync(file, text || '(sem output)');
    doSpawn('open', ['-a', 'TextEdit', file]);
  } catch (err) {
    process.stderr.write(`[deck] openContext ${sessionId}: ${err.message}\n`);
  }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd deck && node --test test/context.test.js`
Expected: PASS (2 tests)

- [ ] **Step 5: Commitar**

```bash
git add deck/src/context.js deck/test/context.test.js
git commit -m "feat(deck): abrir contexto da sessão na tela do Mac"
```

---

### Task 8: Renderer — board → sendState + timer de pulso

**Files:**
- Create: `deck/src/renderer.js`
- Test: `deck/test/renderer.test.js`

**Interfaces:**
- Consumes: `buildBoard` (Task 4), um `ulanziLink` (Task 6, precisa de `handles()` e `sendState()`).
- Produces: `createRenderer({ link }) -> { render(sessions, { page, muted }), startPulse(getState), stopPulse() }`
  - `render`: chama `buildBoard`, e para cada BoardSlot cujo `slot` tem um handle correspondente em `link.handles()`, chama `link.sendState(handle, iconPath, title)`. (O casamento slot→handle usa o mapa preenchido pelos eventos `add`; a correspondência exata slot↔key é confirmada na Task 9 — o renderer aceita um `slotToKey` opcional, default identidade.)
  - `startPulse(getState)`: liga um `setInterval(600ms)` que alterna `pulseOn` e re-renderiza com `getState()` (retorna `{sessions,page,muted}`), só se houver alguma sessão `needs_you` e não `muted`. `stopPulse` limpa.

- [ ] **Step 1: Escrever o teste que falha**

```js
// deck/test/renderer.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRenderer } from '../src/renderer.js';

function fakeLink() {
  const handles = new Map([['0_0', { key: '0_0', actionid: 'a' }]]);
  const sent = [];
  return {
    handles: () => handles,
    sendState: (h, icon, title) => sent.push({ key: h.key, icon, title }),
    _sent: sent,
  };
}

test('render pinta o slot com handle', () => {
  const link = fakeLink();
  const r = createRenderer({ link, slotToKey: (s) => s });
  r.render([{ id: 'b', state: 'needs_you', title: 'b', updated_at: '1' }], { page: 0, muted: false });
  const painted = link._sent.find((x) => x.key === '0_0');
  assert.ok(painted.icon.endsWith('needs_you.png'));
  assert.equal(painted.title, 'b');
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `cd deck && node --test test/renderer.test.js`
Expected: FAIL (`Cannot find module '../src/renderer.js'`)

- [ ] **Step 3: Implementar `deck/src/renderer.js`**

```js
// deck/src/renderer.js
import { buildBoard } from './board.js';

export function createRenderer({ link, slotToKey = (s) => s }) {
  let pulseOn = false;
  let timer = null;

  function render(sessions, { page = 0, muted = false } = {}) {
    const board = buildBoard(sessions, { page, pulseOn, muted });
    const handles = link.handles();
    for (const bs of board) {
      const handle = handles.get(slotToKey(bs.slot));
      if (handle) link.sendState(handle, bs.iconPath, bs.title);
    }
  }

  return {
    render,
    startPulse(getState) {
      stopPulseInternal();
      timer = setInterval(() => {
        const { sessions, page, muted } = getState();
        const hasNeeds = sessions.some((s) => s.state === 'needs_you');
        if (!hasNeeds || muted) return;
        pulseOn = !pulseOn;
        render(sessions, { page, muted });
      }, 600);
    },
    stopPulse: stopPulseInternal,
  };

  function stopPulseInternal() { if (timer) { clearInterval(timer); timer = null; } }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `cd deck && node --test test/renderer.test.js`
Expected: PASS (1 test)

- [ ] **Step 5: Commitar**

```bash
git add deck/src/renderer.js deck/test/renderer.test.js
git commit -m "feat(deck): renderer board->sendState + pulso"
```

---

### Task 9: Ícones, manifest do plugin e fiação (main.js) — integração local

**Files:**
- Create: `deck/scripts/gen-icons.mjs`
- Create: `deck/assets/icons/*.png` (gerados)
- Create: `deck/com.cutuque.deck.ulanziPlugin/manifest.json`
- Create: `deck/com.cutuque.deck.ulanziPlugin/app/index.js`
- Create: `deck/src/main.js`
- Create: `deck/README.md`

**Interfaces:**
- Consumes: todos os módulos acima.
- Produces: `startDeck({ env, argv }) -> { stop() }` em `main.js` — fia config → hubClient → ulanziLink → renderer → context.

- [ ] **Step 1: Gerar os ícones de estado**

`deck/scripts/gen-icons.mjs` desenha PNGs 72×72 de cor sólida (um por estado + `needs_you_dim`) sem dependência externa, escrevendo PNG cru. Rodar:

```bash
cd deck && node scripts/gen-icons.mjs
ls assets/icons   # running.png needs_you.png needs_you_dim.png done.png error.png idle.png
```

(Conteúdo do gerador: PNG mínimo de cor sólida via `zlib.deflateSync` de linhas RGBA das cores de `STATE_COLORS`; `needs_you_dim` = a mesma cor a 40% de brilho.)

- [ ] **Step 2: Escrever `deck/src/main.js`**

```js
// deck/src/main.js
import { resolveConfig } from './config.js';
import { createHubClient } from './hubClient.js';
import { createUlanziLink } from './ulanziLink.js';
import { createRenderer } from './renderer.js';
import { openContext } from './context.js';
import { SESSION_SLOTS } from './board.js';

export function startDeck({ env = process.env, argv = process.argv.slice(2) } = {}) {
  const cfg = resolveConfig(env, argv);
  let page = 0;
  let muted = false;

  const link = createUlanziLink({
    host: cfg.host, port: cfg.port, pluginUUID: cfg.pluginUUID,
    onRun: ({ param }) => {
      // param carrega o settings do botão; sessão configurada em param.id
      if (param && param.id) openContext(param.id, cfg);
    },
    onReady: () => renderer.render(hub.sessions(), { page, muted }),
  });

  const renderer = createRenderer({ link });

  const hub = createHubClient({
    url: cfg.hubWsUrl,
    onChange: (sessions) => renderer.render(sessions, { page, muted }),
  });

  hub.start();
  link.start();
  renderer.startPulse(() => ({ sessions: hub.sessions(), page, muted }));

  return { stop() { renderer.stopPulse(); hub.stop(); link.stop(); } };
}
```

- [ ] **Step 3: Escrever o manifest do plugin** `deck/com.cutuque.deck.ulanziPlugin/manifest.json`

```json
{
  "UUID": "com.cutuque.deck",
  "Name": "Cutuque Deck",
  "Version": "0.1.0",
  "Author": "vxfontes",
  "CodePath": "app/index.js",
  "Actions": [
    {
      "UUID": "com.cutuque.deck.session",
      "Name": "Cutuque Session",
      "Tooltip": "Um slot de sessão do Cutuque",
      "Icon": "../assets/icons/idle",
      "States": [{ "Image": "../assets/icons/idle" }]
    }
  ]
}
```

- [ ] **Step 4: Escrever o entry** `deck/com.cutuque.deck.ulanziPlugin/app/index.js`

```js
// Entrypoint lançado pelo Ulanzi Studio: node app/index.js <host> <port> <lang>
import { startDeck } from '../../src/main.js';
startDeck();
```

- [ ] **Step 5: Empacotar `ws` para o plugin**

```bash
cd deck/com.cutuque.deck.ulanziPlugin
npm init -y >/dev/null && npm install ws >/dev/null
ls node_modules/ws && echo OK
```

- [ ] **Step 6: Rodar toda a suíte de testes**

Run: `cd deck && node --test`
Expected: PASS (todos os testes das Tasks 1–8)

- [ ] **Step 7: Commitar**

```bash
git add deck/scripts/gen-icons.mjs deck/assets/icons deck/src/main.js deck/README.md deck/com.cutuque.deck.ulanziPlugin
git commit -m "feat(deck): ícones, manifest do plugin e fiação main"
```

---

### Task 10: Setup do profile + verificação end-to-end + checagem de compatibilidade

**Files:**
- Create: `deck/scripts/setup-profile.mjs`

**Interfaces:**
- Consumes: `board.js` (`SESSION_SLOTS`, slots globais). Reusa a técnica validada de edição de `manifest.json` do profile Ulanzi.
- Produces: um script que, com o Ulanzi Studio fechado, injeta a action `com.cutuque.deck.session` nos 8 slots de sessão + globais da página ativa do profile alvo, com backup.

- [ ] **Step 1: Instalar o plugin no Ulanzi**

```bash
cp -R deck/com.cutuque.deck.ulanziPlugin \
  "$HOME/Library/Application Support/Ulanzi/UlanziDeck/Plugins/"
```

- [ ] **Step 2: Escrever `deck/scripts/setup-profile.mjs`**

Fecha o Studio (`osascript -e 'quit app "Ulanzi Studio"'`), faz backup do `manifest.json` da página alvo (`*.claude-bak`), escreve nos 8 `SESSION_SLOTS` uma action `com.cutuque.deck.session` (Plugin `{Name:"Cutuque Deck",UUID:"com.cutuque.deck",Version:"0.1.0"}`, `ActionParam:{ id:"" }`, ícone `assets/icons/idle.png`), reabre o Studio. **Precondição:** app fechado (o app sobrescreveria a edição se aberto).

- [ ] **Step 3: Rodar o setup e ligar**

```bash
cd deck && node scripts/setup-profile.mjs
# Reabrir o Studio já ocorre no script; conferir os botões do Cutuque no deck.
```

Expected: 8 botões da action "Cutuque Session" aparecem na página; ao iniciar o plugin (lançado pelo Studio), os botões pintam conforme as sessões do hub. Cada botão precisa do `id` da sessão no ActionParam — no MVP o `main.js` mapeia por POSIÇÃO (slot i → i-ésima sessão da página), então o `param.id` é preenchido pelo próprio plugin ao renderizar, não pela config manual. (Se o roteamento por posição não bastar, ajustar para gravar o `id` no settings via `paramfromplugin` — decisão registrada aqui, endereçar só se necessário.)

- [ ] **Step 4: Verificação end-to-end (com o hub em dev)**

```bash
# Terminal A: subir o hub em dev com sessões-semente
cd hub && CUTUQUE_ENV=dev go run ./cmd/hub &
curl -s -X POST localhost:8787/dev/seed -H "Authorization: Bearer dev-token" | head
```

Conferir no deck: sessões aparecem coloridas por estado; uma sessão em `needs_you` pulsa; apertar um botão abre o output no TextEdit.

- [ ] **Step 5: Checagem de compatibilidade (requisito aditivo)**

Confirmar que nada existente regrediu:

```bash
cd hub && go build ./... && go test ./...      # hub compila e passa igual
git status                                      # só arquivos em deck/ e docs/ mudaram
git diff --name-only master -- app hub | grep -v '^$' && echo "ALERTA: tocou app/hub" || echo "OK: app/ e hub/ intactos"
```

Expected: `go test ./...` PASS; o `git diff` contra `master` não lista nada em `app/` nem `hub/` (fora eventual endpoint aditivo, que não há no MVP).

- [ ] **Step 6: Commitar**

```bash
git add deck/scripts/setup-profile.mjs
git commit -m "feat(deck): setup do profile + verificação e2e"
```

---

## Self-Review

**Spec coverage:**
- Papel ver+agir → board (T4) + context opener (T7). ✅
- Arquitetura hub-cérebro/plugin-fino → hubClient (T5) + ulanziLink (T6) + main (T9). ✅
- Estado→visual (cores + pulso) → colors (T3) + renderer pulso (T8). ✅
- Layout 13 teclas / linha 3 = 3 → SESSION_SLOTS + globais (T4). ✅
- Ordem por prioridade → priority (T2). ✅
- needs_you → abrir contexto no Mac → context (T7). ✅
- Auth bearer + reconexão → config (T1) + hubClient (T5). ✅
- Setup pré-semeado → setup-profile (T10). ✅
- Restrição aditiva/só-leitura → checagem de compatibilidade (T10, Step 5). ✅

**Placeholders:** as duas decisões deixadas em aberto (formato exato de `key`/`actionid`; roteamento por posição vs id no settings) estão explicitamente marcadas como pontos de confirmação na integração (T9/T10), com fallback definido — não são TODOs vagos.

**Type consistency:** `buildBoard`, `sortByPriority`, `paginate`, `iconPathForState`, `createHubClient`, `createUlanziLink`, `sendState`, `createRenderer`, `openContext` usadas com as mesmas assinaturas entre tarefas. ✅
