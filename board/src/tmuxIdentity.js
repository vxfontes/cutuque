import { execSync } from 'node:child_process';
import { basename } from 'node:path';

// Identidade da sessão a partir do tmux. group = nome do socket (tmux -L <group>),
// derivado do caminho do socket em $TMUX; session = nome da sessão atual.
export function tmuxIdentity(env = process.env, runCmd = defaultRun) {
  if (!env.TMUX) {
    return { group: env.HOSTNAME || 'local', session: 'default' };
  }
  const socketPath = String(env.TMUX).split(',')[0];
  const group = basename(socketPath) || 'default';
  let session = 'default';
  try { session = String(runCmd("tmux display-message -p '#S'")).trim() || 'default'; } catch { /* fallback */ }
  return { group, session };
}

function defaultRun(cmd) {
  return execSync(cmd, { encoding: 'utf8' });
}
