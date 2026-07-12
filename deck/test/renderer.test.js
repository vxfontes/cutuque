// deck/test/renderer.test.js
import { test } from 'node:test';
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
