// deck/src/renderer.js
import { buildBoard } from './board.js';

export function createRenderer({ link, slotToKey = (s) => s }) {
  let pulseOn = false;
  let timer = null;

  function render(sessions, { page = 0, muted = false } = {}) {
    const board = buildBoard(sessions, { page, pulseOn, muted });
    const handles = link.handles();
    for (const bs of board) {
      const handle = handles.get(slotToKey(bs.slot));
      if (handle) link.sendState(handle, bs.iconPath, bs.title);
    }
  }

  return {
    render,
    startPulse(getState) {
      stopPulseInternal();
      timer = setInterval(() => {
        const { sessions, page, muted } = getState();
        const hasNeeds = sessions.some((s) => s.state === 'needs_you');
        if (!hasNeeds || muted) return;
        pulseOn = !pulseOn;
        render(sessions, { page, muted });
      }, 600);
    },
    stopPulse: stopPulseInternal,
  };

  function stopPulseInternal() { if (timer) { clearInterval(timer); timer = null; } }
}
