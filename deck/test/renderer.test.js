// deck/test/renderer.test.js
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRenderer } from '../src/renderer.js';

function fakeLink() {
  const handles = new Map([['0_0', { key: '0_0', actionid: 'a' }]]);
  const sent = [];
  return {
    handles: () => handles,
    sendState: (h, icon, title) => sent.push({ key: h.key, icon, title }),
    _sent: sent,
  };
}

test('render pinta o slot com handle', () => {
  const link = fakeLink();
  const r = createRenderer({ link, slotToKey: (s) => s });
  r.render([{ id: 'b', state: 'needs_you', title: 'b', updated_at: '1' }], { page: 0, muted: false });
  const painted = link._sent.find((x) => x.key === '0_0');
  assert.ok(painted.icon.endsWith('needs_you.png'));
  assert.equal(painted.title, 'b');
});

test('startPulse re-renderiza quando há sessão needs_you', () => {
  const link = fakeLink();
  const r = createRenderer({ link, slotToKey: (s) => s });
  mock.timers.enable({ apis: ['setInterval'] });
  try {
    r.startPulse(() => ({
      sessions: [{ id: 'b', state: 'needs_you', title: 'b', updated_at: '1' }],
      page: 0,
      muted: false,
    }));
    link._sent.length = 0;
    mock.timers.tick(600);
    assert.ok(link._sent.some((x) => x.key === '0_0'), 'esperava novo sendState apos o tick do pulso');
  } finally {
    r.stopPulse();
    mock.timers.reset();
  }
});

test('startPulse não re-renderiza quando muted', () => {
  const link = fakeLink();
  const r = createRenderer({ link, slotToKey: (s) => s });
  mock.timers.enable({ apis: ['setInterval'] });
  try {
    r.startPulse(() => ({
      sessions: [{ id: 'b', state: 'needs_you', title: 'b', updated_at: '1' }],
      page: 0,
      muted: true,
    }));
    link._sent.length = 0;
    mock.timers.tick(600);
    assert.equal(link._sent.length, 0, 'nao esperava sendState com muted=true');
  } finally {
    r.stopPulse();
    mock.timers.reset();
  }
});

test('startPulse não re-renderiza quando não há sessão needs_you', () => {
  const link = fakeLink();
  const r = createRenderer({ link, slotToKey: (s) => s });
  mock.timers.enable({ apis: ['setInterval'] });
  try {
    r.startPulse(() => ({
      sessions: [{ id: 'b', state: 'running', title: 'b', updated_at: '1' }],
      page: 0,
      muted: false,
    }));
    link._sent.length = 0;
    mock.timers.tick(600);
    assert.equal(link._sent.length, 0, 'nao esperava sendState sem needs_you');
  } finally {
    r.stopPulse();
    mock.timers.reset();
  }
});

test('stopPulse interrompe novos renders', () => {
  const link = fakeLink();
  const r = createRenderer({ link, slotToKey: (s) => s });
  mock.timers.enable({ apis: ['setInterval'] });
  try {
    r.startPulse(() => ({
      sessions: [{ id: 'b', state: 'needs_you', title: 'b', updated_at: '1' }],
      page: 0,
      muted: false,
    }));
    r.stopPulse();
    link._sent.length = 0;
    mock.timers.tick(600);
    assert.equal(link._sent.length, 0, 'nao esperava sendState apos stopPulse');
  } finally {
    r.stopPulse();
    mock.timers.reset();
  }
});
