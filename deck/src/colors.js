// deck/src/colors.js
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ICONS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'assets', 'icons');

export const STATE_COLORS = {
  running: '#2D7FF9',
  needs_you: '#F5A623',
  done: '#3DC46A',
  error: '#E5484D',
  idle: '#6B7280',
};

export function iconPathForState(state, { pulseOn = false } = {}) {
  const known = STATE_COLORS[state] ? state : 'idle';
  if (known === 'needs_you' && pulseOn) return join(ICONS_DIR, 'needs_you_dim.png');
  return join(ICONS_DIR, `${known}.png`);
}
