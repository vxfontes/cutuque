import { test } from 'node:test';
import assert from 'node:assert/strict';
import { tmuxIdentity } from '../src/tmuxIdentity.js';

test('deriva group do socket TMUX e session do comando', () => {
  const id = tmuxIdentity(
    { TMUX: '/private/tmp/tmux-501/interconexao,12345,0' },
    () => 'cutuque\n',
  );
  assert.equal(id.group, 'interconexao');
  assert.equal(id.session, 'cutuque');
});
test('fora do tmux cai no fallback', () => {
  const id = tmuxIdentity({ HOSTNAME: 'macbook' }, () => { throw new Error('no tmux'); });
  assert.equal(id.group, 'macbook');
  assert.equal(id.session, 'default');
});
test('override CUTUQUE_GROUP/CUTUQUE_SESSION tem prioridade', () => {
  const id = tmuxIdentity(
    { CUTUQUE_GROUP: 'interconexao', CUTUQUE_SESSION: 'cutuque', TMUX: '/tmp/tmux/outro,1,0' },
    () => 'sessao-do-tmux\n',
  );
  assert.equal(id.group, 'interconexao');
  assert.equal(id.session, 'cutuque');
});
test('override parcial combina com tmux', () => {
  const id = tmuxIdentity(
    { CUTUQUE_GROUP: 'meu-grupo', TMUX: '/tmp/tmux/socket,1,0' },
    () => 'sessao-tmux\n',
  );
  assert.equal(id.group, 'meu-grupo');
  assert.equal(id.session, 'sessao-tmux');
});
