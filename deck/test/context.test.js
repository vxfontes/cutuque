// deck/test/context.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { openContext } from '../src/context.js';

test('busca output com Bearer e abre no Mac (formato real: {kind, text})', async (t) => {
  let seenUrl, seenAuth, spawned;
  const fetchImpl = async (url, opts) => {
    seenUrl = url; seenAuth = opts.headers.Authorization;
    return {
      ok: true,
      json: async () => ({
        chunks: [
          { kind: 'stdout', text: 'linha 1\n' },
          { kind: 'stdout', text: 'linha 2\n' },
        ],
      }),
    };
  };
  const spawnImpl = (cmd, args) => { spawned = { cmd, args }; };

  const file = join(tmpdir(), 'cutuque-deck-sess-1.txt');
  t.after(() => { try { unlinkSync(file); } catch {} });

  await openContext('sess-1', { hubBaseUrl: 'http://h:8787', token: 'tok', fetchImpl, spawnImpl });

  assert.equal(seenUrl, 'http://h:8787/sessions/sess-1/output');
  assert.equal(seenAuth, 'Bearer tok');
  assert.equal(spawned.cmd, 'open');
  assert.ok(spawned.args.join(' ').includes('cutuque-deck-sess-1.txt'));
  assert.ok(existsSync(file));
});

test('fallback: chunks no formato antigo {data} ainda funcionam', async (t) => {
  let spawned;
  const fetchImpl = async () => ({
    ok: true,
    json: async () => ({ chunks: [{ data: 'linha 1\n' }, { data: 'linha 2\n' }] }),
  });
  const spawnImpl = (cmd, args) => { spawned = { cmd, args }; };

  const file = join(tmpdir(), 'cutuque-deck-sess-2.txt');
  t.after(() => { try { unlinkSync(file); } catch {} });

  await openContext('sess-2', { hubBaseUrl: 'http://h:8787', token: 'tok', fetchImpl, spawnImpl });

  assert.equal(spawned.cmd, 'open');
  assert.ok(spawned.args.join(' ').includes('cutuque-deck-sess-2.txt'));
  assert.ok(existsSync(file));
});

test('erro de rede não lança', async () => {
  const fetchImpl = async () => { throw new Error('boom'); };
  await assert.doesNotReject(openContext('x', { hubBaseUrl: 'http://h', token: 't', fetchImpl, spawnImpl: () => {} }));
});

test('sessionId malicioso não escreve fora do tmpdir (rejeitado)', async () => {
  let fetchCalled = false;
  let spawnCalled = false;
  const fetchImpl = async () => { fetchCalled = true; return { ok: true, json: async () => ({ chunks: [] }) }; };
  const spawnImpl = () => { spawnCalled = true; };

  await assert.doesNotReject(
    openContext('../../evil', { hubBaseUrl: 'http://h', token: 't', fetchImpl, spawnImpl })
  );

  assert.equal(fetchCalled, false, 'não deve buscar output para sessionId inválido');
  assert.equal(spawnCalled, false, 'não deve abrir arquivo para sessionId inválido');
  assert.ok(!existsSync(join(tmpdir(), '..', '..', 'evil')));
});
