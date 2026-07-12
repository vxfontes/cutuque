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
