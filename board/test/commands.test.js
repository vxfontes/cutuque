import { test } from 'node:test';
import assert from 'node:assert/strict';
import { commands } from '../src/commands.js';

function fakeCli(tasks = []) {
  const out = [];
  const created = [];
  const moved = [];
  return {
    _out: out, _created: created, _moved: moved,
    identity: { group: 'interconexao', session: 'cutuque' },
    out: (s) => out.push(s),
    client: {
      listTasks: async () => tasks,
      createTask: async (t) => { created.push(t); return { ...t, id: 'new1', column: 'a_fazer' }; },
      moveTask: async (id, col) => { moved.push([id, col]); return { id, column: col }; },
    },
  };
}

test('add cria com as tags da identidade e imprime id', async () => {
  const cli = fakeCli();
  await commands.add(cli, 'rodar testes');
  assert.equal(cli._created[0].title, 'rodar testes');
  assert.equal(cli._created[0].group, 'interconexao');
  assert.equal(cli._created[0].session, 'cutuque');
  assert.ok(cli._out.join('\n').includes('new1'));
});

test('list filtra pela sessão atual', async () => {
  const cli = fakeCli([
    { id: 'a', title: 't1', column: 'a_fazer', group: 'interconexao', session: 'cutuque' },
    { id: 'b', title: 't2', column: 'feito', group: 'outro', session: 'x' },
  ]);
  await commands.list(cli);
  const printed = cli._out.join('\n');
  assert.ok(printed.includes('t1'));
  assert.ok(!printed.includes('t2')); // de outra sessão, filtrado
});

test('move chama o client', async () => {
  const cli = fakeCli();
  await commands.move(cli, 'a', 'em_progresso');
  assert.deepEqual(cli._moved[0], ['a', 'em_progresso']);
});
