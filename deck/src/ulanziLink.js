import WS from 'ws';

export function createUlanziLink({ host, port, pluginUUID, WebSocketImpl = WS, onRun = () => {}, onReady = () => {}, onAdd = () => {} }) {
  const handles = new Map(); // key -> { key, actionid }
  let ws = null;
  let stopped = false;
  let retry = null;

  function handle(raw) {
    let d;
    try { d = JSON.parse(raw.toString()); } catch { return; }
    switch (d.cmd) {
      case 'add':
        if (d.key) {
          handles.set(d.key, { key: d.key, actionid: d.actionid });
          onAdd({ key: d.key, actionid: d.actionid, param: d.param });
          onReady();
        }
        break;
      case 'run':
        onRun({ key: d.key, actionid: d.actionid, param: d.param });
        break;
      case 'clear': {
        const list = Array.isArray(d.param) ? d.param : [];
        for (const p of list) handles.delete(p.key);
        break;
      }
      default:
        break;
    }
  }

  function connect() {
    if (stopped) return;
    ws = new WebSocketImpl(`ws://${host}:${port}`);
    ws.on('open', () => ws.send(JSON.stringify({ code: 0, cmd: 'connected', uuid: pluginUUID })));
    ws.on('message', handle);
    ws.on('close', () => { if (!stopped) retry = setTimeout(connect, 2000); });
    ws.on('error', () => {});
  }

  return {
    start() { stopped = false; connect(); },
    stop() { stopped = true; clearTimeout(retry); if (ws) try { ws.close(); } catch {} },
    handles() { return handles; },
    sendState({ key, actionid }, iconPath, title) {
      if (!ws || ws.readyState !== 1) return;
      ws.send(JSON.stringify({
        cmd: 'state', uuid: pluginUUID, key, actionid,
        param: { statelist: [{ uuid: pluginUUID, key, actionid, type: 2, path: iconPath, textData: title || '', showtext: !!title }] },
      }));
    },
  };
}
