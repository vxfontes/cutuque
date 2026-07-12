// deck/src/context.js
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

export async function openContext(sessionId, { hubBaseUrl, token, fetchImpl = fetch, spawnImpl }) {
  const doSpawn = spawnImpl || ((cmd, args) => spawn(cmd, args, { detached: true, stdio: 'ignore' }).unref());
  try {
    const res = await fetchImpl(`${hubBaseUrl}/sessions/${sessionId}/output`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!res.ok) { process.stderr.write(`[deck] output ${sessionId}: HTTP ${res.status}\n`); return; }
    const body = await res.json();
    const text = (body.chunks || []).map((c) => c.data ?? c.text ?? '').join('');
    const file = join(tmpdir(), `cutuque-deck-${sessionId}.txt`);
    writeFileSync(file, text || '(sem output)');
    doSpawn('open', ['-a', 'TextEdit', file]);
  } catch (err) {
    process.stderr.write(`[deck] openContext ${sessionId}: ${err.message}\n`);
  }
}
