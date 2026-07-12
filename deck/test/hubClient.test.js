import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { createHubClient } from '../src/hubClient.js';

// Fake WS: dispara open no próximo tick; expõe emitMessage() pro teste.
class FakeWS extends EventEmitter {
  constructor() {
    super();
    FakeWS.count = (FakeWS.count || 0) + 1;
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

test('reconecta um novo socket 2000ms após close', async (t) => {
  mock.timers.enable({ apis: ['setTimeout'] });
  t.after(() => mock.timers.reset());

  const client = createHubClient({
    url: 'ws://x/ws',
    WebSocketImpl: FakeWS,
    onChange: () => {},
  });
  client.start();
  await Promise.resolve(); // flush o queueMicrotask que emite 'open'

  const first = FakeWS.last;
  const countBefore = FakeWS.count;

  first.close(); // dispara 'close' -> scheduleReconnect agenda setTimeout(connect, 2000)

  mock.timers.tick(2000);

  assert.equal(FakeWS.count, countBefore + 1);
  assert.notEqual(FakeWS.last, first);

  client.stop();
});

test('stop() cancela reconexão pendente', async (t) => {
  mock.timers.enable({ apis: ['setTimeout'] });
  t.after(() => mock.timers.reset());

  const client = createHubClient({
    url: 'ws://x/ws',
    WebSocketImpl: FakeWS,
    onChange: () => {},
  });
  client.start();
  await Promise.resolve(); // flush o queueMicrotask que emite 'open'

  const countBefore = FakeWS.count;

  FakeWS.last.close(); // agenda reconexão em 2000ms
  client.stop(); // deve cancelar o setTimeout pendente

  mock.timers.tick(2000);

  assert.equal(FakeWS.count, countBefore); // nenhum novo socket foi criado
});
