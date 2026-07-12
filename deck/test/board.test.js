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
