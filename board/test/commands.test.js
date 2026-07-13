import { test } from 'node:test';
import assert from 'node:assert/strict';
import { commands, resolveScope, inScope } from '../src/commands.js';

function fakeCli(tasks = [], weeks = []) {
  const out = [];
  const created = [];
  const moved = [];
  const comments = [];
  const patches = [];
  return {
    _out: out, _created: created, _moved: moved, _comments: comments, _patches: patches,
    identity: { group: 'interconexao', session: 'cutuque', type: 'claude', role: 'marcus' },
    out: (s) => out.push(s),
    client: {
      listTasks: async () => tasks,
      createTask: async (t) => { created.push(t); return { ...t, id: 'new1', column: 'a_fazer' }; },
      moveTask: async (id, col) => { moved.push([id, col]); return { id, column: col }; },
      addComment: async (id, author, text) => { comments.push([id, author, text]); return { id }; },
      patchTask: async (id, patch) => { patches.push([id, patch]); return { id, ...patch }; },
      archive: async () => weeks,
      closeWeek: async () => ({ archived: 2, stalled: 1 }),
    },
  };
}

test('add cria com as tags da identidade e imprime id', async () => {
  const cli = fakeCli();
  await commands.add(cli, 'rodar testes');
  assert.equal(cli._created[0].title, 'rodar testes');
  assert.equal(cli._created[0].group, 'interconexao');
  assert.equal(cli._created[0].session, 'cutuque');
  assert.equal(cli._created[0].type, 'claude');
  assert.equal(cli._created[0].role, 'marcus');
  assert.ok(cli._out.join('\n').includes('new1'));
});

test('list mostra o ambiente (grupo) por padrão, inclui outra sessão do mesmo grupo', async () => {
  const cli = fakeCli([
    { id: 'a', title: 't1', column: 'a_fazer', group: 'interconexao', session: 'cutuque' },
    { id: 'c', title: 't3', column: 'em_progresso', group: 'interconexao', session: 'subagente' },
    { id: 'b', title: 't2', column: 'feito', group: 'outro', session: 'x' },
  ]);
  await commands.list(cli, { flags: {} });
  const printed = cli._out.join('\n');
  assert.ok(printed.includes('t1'));
  assert.ok(printed.includes('t3')); // mesma "ambiente" (grupo), outra sessão -> aparece
  assert.ok(!printed.includes('t2')); // outro ambiente -> filtrado
});

test('list --session estreita para a minha sessão', async () => {
  const cli = fakeCli([
    { id: 'a', title: 't1', column: 'a_fazer', group: 'interconexao', session: 'cutuque' },
    { id: 'c', title: 't3', column: 'em_progresso', group: 'interconexao', session: 'subagente' },
  ]);
  await commands.list(cli, { flags: { session: '' } });
  const printed = cli._out.join('\n');
  assert.ok(printed.includes('t1'));
  assert.ok(!printed.includes('t3'));
});

test('list --all mostra todos os ambientes e marca encalhada + comentários', async () => {
  const cli = fakeCli([
    { id: 'a', title: 't1', column: 'a_fazer', group: 'interconexao', session: 'cutuque', encalhada: true, comments: [{}, {}] },
    { id: 'b', title: 't2', column: 'feito', group: 'outro', session: 'x' },
  ]);
  await commands.list(cli, { flags: { all: '' } });
  const printed = cli._out.join('\n');
  assert.ok(printed.includes('t1') && printed.includes('t2'));
  assert.ok(printed.includes('encalhada'));
  assert.ok(printed.includes('2c'));
});

test('resolveScope: padrão grupo, flags ampliam/estreitam', () => {
  const id = { group: 'interconexao', session: 'cutuque' };
  assert.deepEqual(resolveScope(id, {}), { kind: 'group', group: 'interconexao' });
  assert.deepEqual(resolveScope(id, { all: '' }), { kind: 'all' });
  assert.deepEqual(resolveScope(id, { group: 'x' }), { kind: 'group', group: 'x' });
  assert.deepEqual(resolveScope(id, { session: '' }), { kind: 'session', group: 'interconexao', session: 'cutuque' });
});

test('inScope respeita grupo/sessão/all', () => {
  assert.ok(inScope({ group: 'g', session: 's' }, { kind: 'all' }));
  assert.ok(inScope({ group: 'g', session: 's' }, { kind: 'group', group: 'g' }));
  assert.ok(!inScope({ group: 'g', session: 's' }, { kind: 'group', group: 'z' }));
  assert.ok(!inScope({ group: 'g', session: 's2' }, { kind: 'session', group: 'g', session: 's' }));
});

test('week sem label lista as semanas com contagem no escopo', async () => {
  const cli = fakeCli([], [
    { label: '2026-W28', start: '2026-07-06', end: '2026-07-12', tasks: [
      { id: 'a', title: 'concluida', group: 'interconexao', session: 'cutuque', role: 'marcus' },
      { id: 'b', title: 'de outro', group: 'outro', session: 'x' },
    ] },
  ]);
  await commands.week(cli, { flags: {}, args: [] });
  const printed = cli._out.join('\n');
  assert.ok(printed.includes('2026-W28'));
  assert.ok(printed.includes('(1 concluído)')); // só 1 no meu ambiente
});

test('week <label> mostra os cards daquela semana no escopo', async () => {
  const cli = fakeCli([], [
    { label: '2026-W28', start: '2026-07-06', end: '2026-07-12', tasks: [
      { id: 'a', title: 'minha concluida', group: 'interconexao', session: 'cutuque', role: 'marcus' },
      { id: 'b', title: 'de outro', group: 'outro', session: 'x' },
    ] },
  ]);
  await commands.week(cli, { flags: {}, args: ['2026-W28'] });
  const printed = cli._out.join('\n');
  assert.ok(printed.includes('minha concluida'));
  assert.ok(!printed.includes('de outro'));
});

test('close-week reporta arquivados e encalhados', async () => {
  const cli = fakeCli();
  await commands.closeWeek(cli);
  assert.ok(cli._out.join('\n').includes('2 arquivado'));
  assert.ok(cli._out.join('\n').includes('1 encalhado'));
});

test('show traz descricao + todos os comentarios', async () => {
  const cli = fakeCli([
    { id: 'a', title: 'tarefa X', column: 'em_progresso', group: 'interconexao', session: 'cutuque',
      type: 'claude', role: 'marcus', description: 'fazer o X direito',
      comments: [{ author: 'marcus', text: 'comecei' }, { author: 'você', text: 'cuidado com o edge case' }] },
  ]);
  await commands.show(cli, 'a');
  const out = cli._out.join('\n');
  assert.ok(out.includes('tarefa X'));
  assert.ok(out.includes('fazer o X direito'));       // descrição
  assert.ok(out.includes('Comentários (2)'));
  assert.ok(out.includes('marcei') === false);        // sanity
  assert.ok(out.includes('comecei') && out.includes('cuidado com o edge case')); // texto dos comentários
});

test('show procura no arquivo quando nao esta no board ativo', async () => {
  const cli = fakeCli([], [
    { label: '2026-W28', start: '2026-07-06', end: '2026-07-12', tasks: [
      { id: 'z', title: 'arquivada', column: 'concluido', group: 'interconexao', session: 'cutuque',
        comments: [{ author: 'brad', text: 'ficou bom' }] },
    ] },
  ]);
  await commands.show(cli, 'z');
  const out = cli._out.join('\n');
  assert.ok(out.includes('arquivada') && out.includes('ficou bom'));
});

test('show lanca erro se id nao existe', async () => {
  const cli = fakeCli([]);
  await assert.rejects(() => commands.show(cli, 'naoexiste'));
});

test('move chama o client', async () => {
  const cli = fakeCli();
  await commands.move(cli, 'a', 'em_progresso');
  assert.deepEqual(cli._moved[0], ['a', 'em_progresso']);
});

test('comment adiciona com autor = role', async () => {
  const cli = fakeCli();
  await commands.comment(cli, 'abc', 'minha observação');
  assert.deepEqual(cli._comments[0], ['abc', 'marcus', 'minha observação']);
});

test('desc faz patch da descrição', async () => {
  const cli = fakeCli();
  await commands.desc(cli, 'abc', 'nova descrição');
  assert.deepEqual(cli._patches[0], ['abc', { description: 'nova descrição' }]);
});
