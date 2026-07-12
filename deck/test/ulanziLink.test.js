import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { createUlanziLink } from '../src/ulanziLink.js';

class FakeWS extends EventEmitter {
  constructor() { super(); FakeWS.last = this; this.sent = []; this.readyState = 1; queueMicrotask(() => this.emit('open')); }
  send(str) { this.sent.push(JSON.parse(str)); }
  emitMessage(obj) { this.emit('message', Buffer.from(JSON.stringify(obj))); }
  close() { this.readyState = 3; this.emit('close'); }
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

test('clear remove handles', async () => {
  const link = createUlanziLink({ host: '127.0.0.1', port: 3906, pluginUUID: 'com.cutuque.deck', WebSocketImpl: FakeWS });
  link.start();
  await new Promise((r) => setTimeout(r, 5));

  FakeWS.last.emitMessage({ cmd: 'add', key: 'k1', actionid: 'a1' });
  FakeWS.last.emitMessage({ cmd: 'add', key: 'k2', actionid: 'a2' });
  assert.ok(link.handles().get('k1'));
  assert.ok(link.handles().get('k2'));

  FakeWS.last.emitMessage({ cmd: 'clear', param: [{ key: 'k1' }] });
  assert.equal(link.handles().get('k1'), undefined);
  assert.ok(link.handles().get('k2'));

  link.stop();
});

test('sendState apos close nao lanca e nao envia state', async () => {
  const link = createUlanziLink({ host: '127.0.0.1', port: 3906, pluginUUID: 'com.cutuque.deck', WebSocketImpl: FakeWS });
  link.start();
  await new Promise((r) => setTimeout(r, 5));

  FakeWS.last.emitMessage({ cmd: 'add', key: 'k1', actionid: 'a1' });
  const socket = FakeWS.last;
  socket.close();
  const sentBeforeCount = socket.sent.length;

  assert.doesNotThrow(() => {
    link.sendState({ key: 'k1', actionid: 'a1' }, '/x/running.png', 'mac');
  });
  const stateMsgAfterClose = socket.sent.slice(sentBeforeCount).find((m) => m.cmd === 'state');
  assert.equal(stateMsgAfterClose, undefined);

  link.stop();
});
