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
