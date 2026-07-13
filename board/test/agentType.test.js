import { test } from 'node:test';
import assert from 'node:assert/strict';
import { detectAgent } from '../src/agentType.js';

test('override explícito por CUTUQUE_AGENT', () => {
  assert.equal(detectAgent({ CUTUQUE_AGENT: 'codex' }), 'codex');
  assert.equal(detectAgent({ CUTUQUE_AGENT: 'OpenCode' }), 'opencode'); // case-insensitive
});

test('override inválido é ignorado (cai na detecção)', () => {
  assert.equal(detectAgent({ CUTUQUE_AGENT: 'foo', CLAUDECODE: '1' }), 'claude');
});

test('detecta claude por CLAUDECODE / CLAUDE_CODE_*', () => {
  assert.equal(detectAgent({ CLAUDECODE: '1' }), 'claude');
  assert.equal(detectAgent({ CLAUDE_CODE_ENTRYPOINT: 'cli' }), 'claude');
});

test('detecta codex e opencode por prefixo', () => {
  assert.equal(detectAgent({ CODEX_HOME: '/x' }), 'codex');
  assert.equal(detectAgent({ OPENCODE_SESSION: 'y' }), 'opencode');
});

test('dica genérica AI_AGENT', () => {
  assert.equal(detectAgent({ AI_AGENT: 'codex' }), 'codex');
});

test('desconhecido -> string vazia', () => {
  assert.equal(detectAgent({ PATH: '/usr/bin' }), '');
  assert.equal(detectAgent({}), '');
});
