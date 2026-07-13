import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveConfig } from '../src/config.js';

test('defaults de dev', () => {
  const c = resolveConfig({});
  assert.equal(c.hubBaseUrl, 'http://192.0.2.10:8787');
  assert.equal(c.token, 'dev-token');
});
test('respeita env', () => {
  const c = resolveConfig({ CUTUQUE_HUB: 'http://h:9', CUTUQUE_TOKEN: 'tk' });
  assert.equal(c.hubBaseUrl, 'http://h:9');
  assert.equal(c.token, 'tk');
});

test('CUTUQUE_HUB sem esquema (host:porta) ganha http://', () => {
  assert.equal(resolveConfig({ CUTUQUE_HUB: '192.0.2.10:8787' }).hubBaseUrl, 'http://192.0.2.10:8787');
});
