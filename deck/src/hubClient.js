import WS from 'ws';

export function createHubClient({ url, WebSocketImpl = WS, onChange = () => {} }) {
  const sessions = new Map();
  let ws = null;
  let stopped = false;
  let retry = null;

  function emit() {
    onChange([...sessions.values()]);
  }

  function handle(raw) {
    let msg;
    try { msg = JSON.parse(raw.toString()); } catch { return; }
    switch (msg.type) {
      case 'snapshot':
        sessions.clear();
        for (const s of msg.sessions || []) sessions.set(s.id, s);
        emit();
        break;
      case 'session_updated':
        if (msg.session) { sessions.set(msg.session.id, msg.session); emit(); }
        break;
      case 'session_removed':
        if (sessions.delete(msg.session_id)) emit();
        break;
      default:
        break; // output_chunk etc. ignorados
    }
  }

  function connect() {
    if (stopped) return;
    ws = new WebSocketImpl(url);
    ws.on('message', handle);
    ws.on('close', scheduleReconnect);
    ws.on('error', () => {}); // 'close' cuida da reconexão
  }

  function scheduleReconnect() {
    if (stopped) return;
    retry = setTimeout(connect, 2000);
  }

  return {
    start() { stopped = false; connect(); },
    stop() { stopped = true; clearTimeout(retry); if (ws) try { ws.close(); } catch {} },
    sessions() { return [...sessions.values()]; },
  };
}
