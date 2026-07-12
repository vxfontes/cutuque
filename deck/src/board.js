// deck/src/board.js
import { sortByPriority, paginate } from './priority.js';
import { iconPathForState } from './colors.js';

export const SESSION_SLOTS = ['0_0', '1_0', '2_0', '3_0', '4_0', '0_1', '1_1', '2_1'];
export const PREV_SLOT = '3_1';
export const NEXT_SLOT = '4_1';
export const MACHINE_SLOT = '0_2';
export const MUTE_SLOT = '1_2';
export const MENU_SLOT = '2_2';

export function buildBoard(sessions, { page = 0, pulseOn = false, muted = false } = {}) {
  const sorted = sortByPriority(sessions);
  const pg = paginate(sorted, page, SESSION_SLOTS.length);
  const slots = [];

  SESSION_SLOTS.forEach((slot, i) => {
    const session = pg.items[i] || null;
    if (!session) {
      slots.push({ slot, kind: 'session', session: null, iconPath: '', title: '' });
      return;
    }
    const pulse = session.state === 'needs_you' && pulseOn && !muted;
    slots.push({
      slot,
      kind: 'session',
      session,
      iconPath: iconPathForState(session.state, { pulseOn: pulse }),
      title: session.title || session.machine || session.id,
    });
  });

  if (pg.hasPrev) slots.push({ slot: PREV_SLOT, kind: 'prev', iconPath: '', title: '◀' });
  if (pg.hasNext) slots.push({ slot: NEXT_SLOT, kind: 'next', iconPath: '', title: '▶' });

  slots.push({ slot: MACHINE_SLOT, kind: 'machine', iconPath: '', title: '🖥' });
  slots.push({ slot: MUTE_SLOT, kind: 'mute', iconPath: '', title: muted ? '🔕' : '🔔' });
  slots.push({ slot: MENU_SLOT, kind: 'menu', iconPath: '', title: '⚙' });

  return slots;
}
