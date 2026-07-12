// deck/test/main.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startDeck } from '../src/main.js';

function makeFakeUlanziLink() {
  const calls = { start: 0, stop: 0 };
  let capturedOnRun, capturedOnReady;
  const fake = {
    createUlanziLink(opts) {
      capturedOnRun = opts.onRun;
      capturedOnReady = opts.onReady;
      return {
        start() { calls.start += 1; },
        stop() { calls.stop += 1; },
        handles() { return new Map(); },
        sendState() {},
      };
    },
  };
  return { fake, calls, getOnRun: () => capturedOnRun, getOnReady: () => capturedOnReady };
}

function makeFakeHubClient() {
  const calls = { start: 0, stop: 0 };
  let capturedOnChange;
  const fake = {
    createHubClient(opts) {
      capturedOnChange = opts.onChange;
      return {
        start() { calls.start += 1; },
        stop() { calls.stop += 1; },
        sessions() { return []; },
      };
    },
  };
  return { fake, calls, getOnChange: () => capturedOnChange };
}

function makeFakeRenderer() {
  const calls = { render: [], startPulse: 0, stopPulse: 0 };
  const fake = {
    createRenderer() {
      return {
        render(sessions, state) { calls.render.push({ sessions, state }); },
        startPulse(getState) { calls.startPulse += 1; void getState; /* não inicia timer real */ },
        stopPulse() { calls.stopPulse += 1; },
      };
    },
  };
  return { fake, calls };
}

test('startDeck: constrói hub client e ulanzi link e os inicia', () => {
  const ulanzi = makeFakeUlanziLink();
  const hub = makeFakeHubClient();
  const renderer = makeFakeRenderer();
  const openContextCalls = [];

  const deck = startDeck({
    env: {},
    argv: [],
    deps: {
      createUlanziLink: ulanzi.fake.createUlanziLink,
      createHubClient: hub.fake.createHubClient,
      createRenderer: renderer.fake.createRenderer,
      openContext: (id) => { openContextCalls.push(id); },
    },
  });

  assert.equal(ulanzi.calls.start, 1);
  assert.equal(hub.calls.start, 1);

  deck.stop();
});

test('startDeck: onRun do ulanzi chama openContext injetado com param.id', () => {
  const ulanzi = makeFakeUlanziLink();
  const hub = makeFakeHubClient();
  const renderer = makeFakeRenderer();
  const openContextCalls = [];

  const deck = startDeck({
    env: {},
    argv: [],
    deps: {
      createUlanziLink: ulanzi.fake.createUlanziLink,
      createHubClient: hub.fake.createHubClient,
      createRenderer: renderer.fake.createRenderer,
      openContext: (id) => { openContextCalls.push(id); },
    },
  });

  const onRun = ulanzi.getOnRun();
  assert.equal(typeof onRun, 'function');
  onRun({ param: { id: 'sess-1' } });

  assert.deepEqual(openContextCalls, ['sess-1']);

  deck.stop();
});

test('startDeck: onChange do hub chama renderer.render', () => {
  const ulanzi = makeFakeUlanziLink();
  const hub = makeFakeHubClient();
  const renderer = makeFakeRenderer();

  const deck = startDeck({
    env: {},
    argv: [],
    deps: {
      createUlanziLink: ulanzi.fake.createUlanziLink,
      createHubClient: hub.fake.createHubClient,
      createRenderer: renderer.fake.createRenderer,
      openContext: () => {},
    },
  });

  const onChange = hub.getOnChange();
  assert.equal(typeof onChange, 'function');
  const sessions = [{ id: 'a', state: 'idle', updated_at: '2026-01-01T00:00:00Z' }];
  onChange(sessions);

  assert.equal(renderer.calls.render.length, 1);
  assert.equal(renderer.calls.render[0].sessions, sessions);

  deck.stop();
});

test('startDeck: stop() chama renderer.stopPulse + hub.stop + link.stop', () => {
  const ulanzi = makeFakeUlanziLink();
  const hub = makeFakeHubClient();
  const renderer = makeFakeRenderer();

  const deck = startDeck({
    env: {},
    argv: [],
    deps: {
      createUlanziLink: ulanzi.fake.createUlanziLink,
      createHubClient: hub.fake.createHubClient,
      createRenderer: renderer.fake.createRenderer,
      openContext: () => {},
    },
  });

  deck.stop();

  assert.equal(renderer.calls.stopPulse, 1);
  assert.equal(hub.calls.stop, 1);
  assert.equal(ulanzi.calls.stop, 1);
});
