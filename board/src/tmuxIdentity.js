import { execSync } from 'node:child_process';
import { basename } from 'node:path';

// Identidade da sessão. Prioridade: override explícito (CUTUQUE_GROUP/
// CUTUQUE_SESSION) > detecção pelo tmux (group = nome do socket em $TMUX,
// session = sessão atual) > fallback (hostname/default). O override é útil quando
// a CLI roda fora do tmux (ex.: um shell não-interativo) e o auto-detect não vê.
export function tmuxIdentity(env = process.env, runCmd = defaultRun) {
  const ovGroup = (env.CUTUQUE_GROUP || '').trim();
  const ovSession = (env.CUTUQUE_SESSION || '').trim();

  let group = ovGroup;
  let session = ovSession;

  if ((!group || !session) && env.TMUX) {
    if (!group) group = basename(String(env.TMUX).split(',')[0]) || '';
    if (!session) {
      try { session = String(runCmd("tmux display-message -p '#S'")).trim(); } catch { /* fallback */ }
    }
  }

  return {
    group: group || env.HOSTNAME || 'local',
    session: session || 'default',
  };
}

function defaultRun(cmd) {
  return execSync(cmd, { encoding: 'utf8' });
}
