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
  assert.equal(c.pluginUUID, 'com.cutuque.agents.deck');
});

test('respeita env e argv do Studio', () => {
  const c = resolveConfig(
    { CUTUQUE_TOKEN: 'abc', CUTUQUE_DECK_HUB: 'https://192.0.2.10:8787' },
    ['127.0.0.1', '3906', 'pt-PT']
  );
  assert.equal(c.token, 'abc');
  assert.equal(c.hubWsUrl, 'wss://192.0.2.10:8787/ws?token=abc');
});
