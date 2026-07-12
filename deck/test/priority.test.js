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
