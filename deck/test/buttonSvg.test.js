import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buttonSvg, emptySvg, wrap, projectName } from '../src/buttonSvg.js';

test('projectName: .maestri/roles/{uuid} -> repo antes do .maestri', () => {
  assert.equal(
    projectName('/Users/example/Desktop/coding/acme/.maestri/roles/8c8575fc-1d68-4753-b6fc-5b39ad82c392'),
    'acme',
  );
});

test('projectName: cwd normal -> última pasta', () => {
  assert.equal(projectName('/Users/example/Desktop/coding/personal/cutuque'), 'cutuque');
});

test('projectName: última pasta é uuid -> pula para a anterior', () => {
  assert.equal(projectName('/repo/meuapp/3c30c8cd-49d8-449e-9bf8-2baba351ff55'), 'meuapp');
});

test('projectName: vazio/sem cwd -> null', () => {
  assert.equal(projectName(''), null);
  assert.equal(projectName(undefined), null);
});

function decode(dataUri) {
  assert.ok(dataUri.startsWith('data:image/svg+xml;base64,'), 'esperava data URI SVG base64');
  return Buffer.from(dataUri.split(',')[1], 'base64').toString('utf8');
}

test('buttonSvg gera data URI com nome, estado e cor', () => {
  const svg = decode(buttonSvg({ id: 'x', state: 'running', title: 'refatorar auth', machine: 'macbook', updated_at: '1' }));
  assert.match(svg, /refatorar/); // nome pode quebrar em 2 linhas
  assert.match(svg, /auth/);
  assert.match(svg, /running/);
  assert.match(svg, /#2d7ff9/); // cor de running
});

test('estado desconhecido cai em idle (cinza)', () => {
  const svg = decode(buttonSvg({ id: 'x', state: 'zzz', title: 'a', updated_at: '1' }));
  assert.match(svg, /#6b7280/);
});

test('session null gera card vazio (sem nome)', () => {
  const svg = decode(buttonSvg(null));
  assert.match(svg, /stroke-dasharray/); // moldura tracejada do card vazio
});

test('emptySvg é um data URI', () => {
  assert.ok(emptySvg().startsWith('data:image/svg+xml;base64,'));
});

test('escapa caracteres especiais no nome (sem quebrar o SVG)', () => {
  const svg = decode(buttonSvg({ id: 'x', state: 'done', title: 'a <b> & "c"', updated_at: '1' }));
  assert.match(svg, /&lt;b&gt;/);
  assert.match(svg, /&amp;/);
  assert.doesNotMatch(svg, /<b>/); // não deve conter a tag crua
});

test('needs_you com pulseOn usa acento mais fraco', () => {
  const on = decode(buttonSvg({ id: 'x', state: 'needs_you', title: 'a', updated_at: '1' }, { pulseOn: true }));
  const off = decode(buttonSvg({ id: 'x', state: 'needs_you', title: 'a', updated_at: '1' }, { pulseOn: false }));
  assert.match(on, /#c07f16/);   // âmbar escurecido
  assert.match(off, /#f5a623/);  // âmbar cheio
});

test('wrap quebra em no máximo N linhas e trunca com reticências', () => {
  const lines = wrap('uma sessao com um nome bem grande demais mesmo', 12, 2);
  assert.equal(lines.length, 2);
  assert.ok(lines[1].endsWith('…'));
});
