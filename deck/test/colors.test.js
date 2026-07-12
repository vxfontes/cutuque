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
