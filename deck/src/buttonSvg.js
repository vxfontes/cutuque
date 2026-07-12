// Gera a imagem (SVG -> data URI base64) de cada botão do deck, no estilo
// "command center": card escuro, barra de acento colorida, glifo de status,
// nome da sessão e rótulo do estado. O deck aceita `data:image/svg+xml;base64,…`
// via o comando `state` (type 1) — confirmado no hardware.

const STATE = {
  running:   { color: '#2d7ff9', glyph: '●', label: 'running' },   // ●
  needs_you: { color: '#f5a623', glyph: '◐', label: 'needs you' }, // ◐
  done:      { color: '#3dc46a', glyph: '✓', label: 'done' },      // ✓
  error:     { color: '#e5484d', glyph: '✕', label: 'error' },     // ✕
  idle:      { color: '#6b7280', glyph: '○', label: 'idle' },      // ○
};

function esc(t) {
  return String(t ?? '').replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

// Quebra o nome em até `maxLines` linhas de ~`maxChars` caracteres, com "…" se
// estourar. SVG não faz wrap sozinho, então fazemos aqui.
function wrap(name, maxChars, maxLines) {
  const words = String(name || '').trim().split(/\s+/);
  const lines = [];
  let cur = '';
  for (const w of words) {
    const cand = cur ? `${cur} ${w}` : w;
    if (cand.length <= maxChars) { cur = cand; continue; }
    if (cur) lines.push(cur);
    cur = w.length > maxChars ? `${w.slice(0, maxChars - 1)}…` : w;
    if (lines.length === maxLines) break;
  }
  if (cur && lines.length < maxLines) lines.push(cur);
  if (lines.length === maxLines) {
    const consumed = lines.join(' ').length;
    if (consumed < String(name || '').trim().length) {
      let last = lines[maxLines - 1];
      if (last.length > maxChars - 1) last = last.slice(0, maxChars - 1);
      lines[maxLines - 1] = `${last}…`;
    }
  }
  return lines.length ? lines : [''];
}

function toDataUri(svg) {
  const b64 = (typeof Buffer !== 'undefined')
    ? Buffer.from(svg).toString('base64')
    : btoa(unescape(encodeURIComponent(svg)));
  return `data:image/svg+xml;base64,${b64}`;
}

// buttonSvg(session, opts) -> data URI. session null/undefined => card vazio.
// opts.pulseOn (needs_you) escurece levemente o acento para o efeito de pulso.
export function buttonSvg(session, { pulseOn = false } = {}) {
  if (!session) return emptySvg();
  const st = STATE[session.state] || STATE.idle;
  let accent = st.color;
  if (session.state === 'needs_you' && pulseOn) accent = '#c07f16'; // âmbar mais fraco

  const nameLines = wrap(session.title || session.machine || session.id, 12, 2);

  const nameTspans = nameLines
    .map((ln, i) => `<text x="18" y="${118 + i * 28}" fill="#e9eef5" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="25" font-weight="700">${esc(ln)}</text>`)
    .join('');

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="196" height="196" viewBox="0 0 196 196">
  <defs><radialGradient id="g" cx="30%" cy="0%" r="90%">
    <stop offset="0%" stop-color="${accent}" stop-opacity="0.22"/>
    <stop offset="60%" stop-color="${accent}" stop-opacity="0"/>
  </radialGradient></defs>
  <rect width="196" height="196" rx="26" fill="#0f131b"/>
  <rect width="196" height="196" rx="26" fill="url(#g)"/>
  <rect x="0" y="0" width="9" height="196" rx="4" fill="${accent}"/>
  <circle cx="40" cy="42" r="19" fill="${accent}" fill-opacity="0.16" stroke="${accent}" stroke-width="2.5"/>
  <text x="40" y="52" fill="${accent}" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="24" font-weight="700" text-anchor="middle">${st.glyph}</text>
  ${nameTspans}
  <text x="18" y="176" fill="${accent}" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="17" font-weight="600">${esc(st.label)}</text>
</svg>`;
  return toDataUri(svg);
}

// Card vazio (slot sem sessão): fundo escuro sutil, sem conteúdo.
export function emptySvg() {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="196" height="196" viewBox="0 0 196 196">
  <rect width="196" height="196" rx="26" fill="#0c0f15"/>
  <rect x="12" y="12" width="172" height="172" rx="18" fill="none" stroke="#1b212c" stroke-width="2" stroke-dasharray="5 7"/>
</svg>`;
  return toDataUri(svg);
}

export const _STATE = STATE;
export { wrap };
