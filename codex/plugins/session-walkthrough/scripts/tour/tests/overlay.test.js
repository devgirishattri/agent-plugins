'use strict';
// node --test scripts/tour/tests/overlay.test.js
// Pure placement and navigation math, plus runtime behaviour against a small
// DOM shim: cleanup completeness, sessionStorage restore and the setInterval
// guard. The example tour in examples/live-tour is checked as a fixture.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const vm = require('node:vm');

const api = require('../overlay.js');
const { createWindow, snapshot, FakeEvent } = require('./fake-dom.js');

const PLUGIN = path.resolve(__dirname, '..', '..', '..');
const DEMO_TOUR = path.join(PLUGIN, 'examples', 'live-tour', 'demo-tour.js');
const VP = { width: 1280, height: 800 };
const CARD = { width: 350, height: 200 };

function overlaps(placement) {
  return api.rectsOverlap(
    { left: placement.left, top: placement.top, width: placement.width, height: placement.height },
    placement.target
  );
}

// ---------------------------------------------------------------------------
// Placement math
// ---------------------------------------------------------------------------

test('clampRect intersects with the viewport and drops off-screen rectangles', () => {
  assert.deepEqual(api.clampRect({ left: -50, top: 10, width: 2000, height: 100 }, VP),
    { left: 0, top: 10, right: 1280, bottom: 110, width: 1280, height: 100 });
  assert.equal(api.clampRect({ left: 0, top: 900, width: 10, height: 10 }, VP), null);
  assert.equal(api.clampRect({ left: 10, top: 10, width: 0, height: 10 }, VP), null);
  assert.equal(api.clampRect(null, VP), null);
});

test('placement prefers below when there is room', () => {
  const p = api.computePlacement({ left: 100, top: 100, width: 200, height: 40 }, VP, CARD, { gap: 12, margin: 8 });
  assert.equal(p.side, 'below');
  assert.equal(p.top, 152);
  assert.equal(p.left, 100);
  assert.equal(p.overlaps, false);
});

test('placement goes above when the target sits near the bottom', () => {
  const p = api.computePlacement({ left: 100, top: 700, width: 200, height: 40 }, VP, CARD, { gap: 12, margin: 8 });
  assert.equal(p.side, 'above');
  assert.equal(p.top, 700 - 12 - 200);
  assert.equal(overlaps(p), false);
});

test('placement goes right, then left, when a tall target leaves no vertical room', () => {
  const right = api.computePlacement({ left: 50, top: 20, width: 300, height: 760 }, VP, CARD, { gap: 12, margin: 8 });
  assert.equal(right.side, 'right');
  assert.equal(right.left, 362);
  assert.equal(overlaps(right), false);
  const left = api.computePlacement({ left: 900, top: 20, width: 300, height: 760 }, VP, CARD, { gap: 12, margin: 8 });
  assert.equal(left.side, 'left');
  assert.equal(left.left, 900 - 12 - 350);
  assert.equal(overlaps(left), false);
});

test('placement clamps the card horizontally inside the viewport', () => {
  const p = api.computePlacement({ left: 1200, top: 100, width: 60, height: 30 }, VP, CARD, { gap: 12, margin: 8 });
  assert.equal(p.side, 'below');
  assert.equal(p.left, 1280 - 8 - 350);
  const q = api.computePlacement({ left: -40, top: 100, width: 60, height: 30 }, VP, CARD, { gap: 12, margin: 8 });
  assert.equal(q.left, 8);
});

test('a wide scrolling table is clamped to the viewport before placement', () => {
  const table = { left: 120, top: 300, width: 1800, height: 140 };
  const p = api.computePlacement(table, VP, CARD, { gap: 12, margin: 8, padding: 4 });
  assert.equal(p.target.right, 1280, 'the target is clamped at the right edge');
  assert.equal(p.target.left, 116);
  assert.equal(p.side, 'below');
  assert.equal(overlaps(p), false);
  assert.ok(p.left + p.width <= 1280 - 8);
});

test('placement falls back to the far bottom corner and never covers the target when avoidable', () => {
  // A wide band: no side has room, the bottom corners touch it, the top-left does not.
  const band = { left: 300, top: 210, width: 900, height: 150 };
  const p = api.computePlacement(band, { width: 1280, height: 500 }, CARD, { gap: 12, margin: 8 });
  assert.equal(p.side, 'corner');
  assert.equal(p.corner, 'top-left');
  assert.equal(p.overlaps, false);
  // Target on the right half: the far bottom corner is bottom-left.
  const small = api.computePlacement({ left: 1000, top: 360, width: 200, height: 60 }, { width: 1280, height: 600 },
    { width: 350, height: 260 }, { gap: 12, margin: 8, order: [] });
  assert.equal(small.corner, 'bottom-left');
  assert.equal(small.left, 8);
  assert.equal(small.top, 600 - 8 - 260);
});

test('placement reports an unavoidable overlap instead of hiding it', () => {
  const whole = { left: 0, top: 0, width: 1280, height: 800 };
  const p = api.computePlacement(whole, VP, CARD, {});
  assert.equal(p.side, 'corner');
  assert.equal(p.overlaps, true);
});

test('a missing target puts the card in the bottom-right corner', () => {
  const p = api.computePlacement(null, VP, CARD, { margin: 8 });
  assert.equal(p.side, 'corner');
  assert.equal(p.corner, 'bottom-right');
  assert.equal(p.target, null);
  assert.equal(p.left, 1280 - 8 - 350);
  assert.equal(p.top, 800 - 8 - 200);
});

test('the card is at most 350px wide and shrinks on narrow viewports', () => {
  assert.equal(api.cardWidthFor({ width: 1280, height: 800 }), 350);
  assert.equal(api.cardWidthFor({ width: 320, height: 640 }, 350, 8), 304);
  const p = api.computePlacement({ left: 10, top: 10, width: 100, height: 20 }, { width: 320, height: 640 },
    { width: 350, height: 200 }, { margin: 8 });
  assert.equal(p.width, 304);
});

test('fitScrollDelta scrolls a tall band so the card fits below it, and gives up on oversized targets', () => {
  const band = { left: 0, top: 200, width: 1280, height: 400 };
  const delta = api.fitScrollDelta(band, VP, CARD, { gap: 12, margin: 8 });
  assert.ok(delta > 0);
  const moved = { ...band, top: band.top - delta };
  const p = api.computePlacement(moved, VP, CARD, { gap: 12, margin: 8 });
  assert.equal(p.side, 'below');
  assert.equal(p.overlaps, false);
  assert.equal(api.fitScrollDelta({ left: 0, top: 0, width: 1280, height: 790 }, VP, CARD, {}), null);
  assert.equal(api.fitScrollDelta({ left: 10, top: 10, width: 10, height: 10 }, VP, CARD, {}), 0);
});

// ---------------------------------------------------------------------------
// Navigation state machine
// ---------------------------------------------------------------------------

test('navigation moves within bounds and closes on close or finish', () => {
  let s = { index: 0, total: 3, closed: false };
  s = api.navReduce(s, { type: 'prev' });
  assert.equal(s.index, 0);
  s = api.navReduce(s, { type: 'next' });
  s = api.navReduce(s, { type: 'next' });
  assert.equal(s.index, 2);
  s = api.navReduce(s, { type: 'next' });
  assert.equal(s.index, 2, 'next on the last step stays');
  assert.equal(s.closed, false);
  s = api.navReduce(s, { type: 'goto', index: 99 });
  assert.equal(s.index, 2);
  s = api.navReduce(s, { type: 'goto', index: -5 });
  assert.equal(s.index, 0);
  assert.equal(api.navReduce(s, { type: 'finish' }).closed, true);
  const closed = api.navReduce(s, { type: 'close' });
  assert.equal(closed.closed, true);
  assert.deepEqual(api.navReduce(closed, { type: 'next' }), closed, 'a closed tour ignores input');
  assert.notEqual(api.navReduce(s, { type: 'unknown' }), s, 'the reducer never mutates its input');
});

test('keys map to navigation actions', () => {
  assert.deepEqual(api.keyToAction('ArrowRight'), { type: 'next' });
  assert.deepEqual(api.keyToAction('ArrowLeft'), { type: 'prev' });
  assert.deepEqual(api.keyToAction('Escape'), { type: 'close' });
  assert.equal(api.keyToAction('Enter'), null);
});

// ---------------------------------------------------------------------------
// Tour validation and the demo fixture
// ---------------------------------------------------------------------------

test('validateTour requires a target and exactly one of quote or designDecision', () => {
  const ok = { id: 't', steps: [{ id: 'a', title: 'A', target: '#a', quote: 'x' }] };
  assert.deepEqual(api.validateTour(ok), []);
  const bad = {
    id: 't',
    steps: [
      { id: 'a', title: 'A', quote: 'x' },
      { id: 'b', title: 'B', target: '#b' },
      { id: 'c', title: 'C', target: '#c', quote: 'x', designDecision: 'y' },
      { id: 'c', title: 'D', target: '#d', quote: 'x', actions: [{ label: 'no run' }] }
    ]
  };
  const problems = api.validateTour(bad).join('\n');
  assert.match(problems, /step 1: target/);
  assert.match(problems, /step 2: needs exactly one of quote or designDecision/);
  assert.match(problems, /step 3: needs exactly one/);
  assert.match(problems, /step 4: duplicate id c/);
  assert.match(problems, /step 4: action 1 needs a label and a run function/);
});

test('fixture: every demo-tour step has a target and a quote or a design decision', () => {
  const defineTour = require(DEMO_TOUR);
  const tour = defineTour(api);
  assert.deepEqual(api.validateTour(tour), []);
  assert.ok(tour.steps.length >= 7 && tour.steps.length <= 10, 'about eight steps');
  for (const step of tour.steps) {
    assert.ok(typeof step.target === 'string' || typeof step.target === 'function', step.id + ' target');
    assert.ok(Boolean(step.quote) !== Boolean(step.designDecision), step.id + ' quote xor designDecision');
  }
});

test('fixture: the demo tour demonstrates every overlay feature', () => {
  const tour = require(DEMO_TOUR)(api);
  const steps = tour.steps;
  assert.ok(steps.some((s) => typeof s.setup === 'function'), 'setup');
  assert.ok(steps.some((s) => s.poll && s.poll.timeout), 'poll');
  assert.ok(steps.some((s) => s.poll && s.poll.hiddenReason), 'hidden-element explanation');
  assert.ok(steps.some((s) => Array.isArray(s.actions) && s.actions.length), 'action');
  assert.ok(steps.some((s) => s.watch && typeof s.watch.check === 'function'), 'watch');
  assert.ok(steps.some((s) => s.designDecision), 'design decision');
  assert.ok(steps.some((s) => typeof s.body === 'function'), 'live body text');
  assert.equal(steps[steps.length - 1].title, 'Not shown', 'final Not shown step');
  assert.equal(typeof tour.guard.setInterval, 'function', 'setInterval guard');
});

test('fixture: demo-tour actions only set controls', () => {
  const source = fs.readFileSync(DEMO_TOUR, 'utf8');
  const runs = source.split('run: function').slice(1).map((chunk) => chunk.split('\n          }')[0]);
  assert.ok(runs.length >= 3);
  for (const body of runs) {
    assert.doesNotMatch(body, /\.submit\(|requestSubmit|ctx\.click|save\(|fetch\(|XMLHttpRequest/, body);
    assert.match(body, /ctx\.setValue/);
  }
});

test('fixture: the demo page is synthetic and self-contained', () => {
  const html = fs.readFileSync(path.join(PLUGIN, 'examples', 'live-tour', 'demo.html'), 'utf8');
  assert.doesNotMatch(html, /https?:\/\//, 'no network URLs');
  assert.doesNotMatch(html, /fetch\(|XMLHttpRequest|WebSocket/, 'no network calls');
  assert.doesNotMatch(html, /\balert\(|\bconfirm\(|\bprompt\(/, 'no native dialogs');
  assert.doesNotMatch(html, /@[a-z0-9-]+\.[a-z]{2,}/i, 'no e-mail addresses');
  for (const id of ['order-menu-button', 'action-create-ticket', 'dirty-banner', 'ticket-filter', 'associations-body',
    'refresh-status', 'line-items-table', 'admin-refund', 'save-button']) {
    assert.match(html, new RegExp('id="' + id + '"'), id);
  }
});

test('the overlay source never uses native dialogs', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'overlay.js'), 'utf8');
  assert.doesNotMatch(source, /\balert\(|\bconfirm\(|\bprompt\(/);
  assert.doesNotMatch(source, /innerHTML/);
});

// ---------------------------------------------------------------------------
// Runtime against the DOM shim
// ---------------------------------------------------------------------------

function pageWith(win, ids) {
  const els = {};
  for (const [id, rect] of Object.entries(ids)) {
    const el = win.document.createElement('div');
    el.setAttribute('id', id);
    el.rect = rect;
    win.document.body.appendChild(el);
    els[id] = el;
  }
  return els;
}

function simpleTour(extra) {
  return function simple() {
    return Object.assign({
      id: 'simple',
      steps: [
        { id: 'one', title: 'One', target: '#a', quote: 'first line' },
        { id: 'two', title: 'Two', target: '#b', designDecision: 'chosen', body: () => 'live' },
        { id: 'three', title: 'Three', target: '#missing', quote: 'third', poll: { timeout: 50, hiddenReason: 'hidden for this role' } }
      ]
    }, extra || {});
  };
}

const RECTS = { a: { left: 100, top: 100, width: 200, height: 40 }, b: { left: 600, top: 500, width: 100, height: 40 } };

test('runtime: steps highlight their targets, explain missing ones and respond to keys', async () => {
  const win = createWindow();
  pageWith(win, RECTS);
  const c = api.start(simpleTour(), { window: win });
  let st = await c.ready();
  assert.equal(st.step, 1);
  assert.equal(st.stepId, 'one');
  assert.equal(st.side, 'below');
  assert.equal(st.overlaps, false);
  const card = win.document.querySelector('.swt-card');
  assert.equal(card.getAttribute('role'), 'dialog');
  assert.match(card.textContent, /Step 1 of 3/);
  assert.match(card.textContent, /“first line”/);
  const live = win.document.querySelector('[aria-live]');
  assert.match(live.textContent, /Step 1 of 3: One/);

  const keydown = (key, target) => {
    const e = new FakeEvent('keydown', { key, bubbles: true });
    (target || win.document.body).dispatchEvent(e);
    return e;
  };
  const input = win.document.createElement('input');
  win.document.body.appendChild(input);
  keydown('ArrowRight', input);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(c.status().step, 1, 'arrows typed into a field stay with the field');

  keydown('ArrowRight');
  st = await c.ready();
  assert.equal(st.step, 2);
  assert.match(card.textContent, /Design decision/);
  assert.match(card.textContent, /live/);

  st = await c.goTo(2);
  assert.equal(st.missing, true);
  assert.equal(st.reason, 'hidden for this role');
  assert.match(card.textContent, /Not shown here: hidden for this role/);
  assert.equal(st.side, 'corner');

  keydown('ArrowLeft');
  assert.equal((await c.ready()).step, 2);
  keydown('Escape');
  assert.equal(c.status().open, false);
});

test('runtime: ready() resolves at once when the step is already shown', async () => {
  const win = createWindow();
  pageWith(win, RECTS);
  const c = api.start(simpleTour(), { window: win });
  await c.ready();
  const st = await Promise.race([c.ready(), new Promise((r) => setTimeout(() => r('timeout'), 200))]);
  assert.notEqual(st, 'timeout');
  assert.equal(st.step, 1);
  assert.equal((await api.whenReady(win)).step, 1);
  c.close();
});

test('cleanup: Close leaves no nodes, listeners, storage keys or wrapped globals', async () => {
  const win = createWindow();
  pageWith(win, RECTS);
  win.SessionWalkthroughTour = api;
  const before = snapshot(win);
  const nativeSetInterval = win.setInterval;
  const c = api.start(simpleTour({ guard: { setInterval: () => true } }), { window: win });
  await c.ready();
  const during = snapshot(win);
  assert.ok(during.nodeCount > before.nodeCount);
  assert.ok(during.documentListeners > before.documentListeners);
  assert.ok(during.windowListeners > before.windowListeners);
  assert.ok(during.elementListeners > 0);
  assert.deepEqual(during.storageKeys, [api.STORAGE_KEY]);
  assert.notEqual(win.setInterval, nativeSetInterval);
  assert.ok(win[api.CONTROLLER_KEY]);

  c.close();
  const after = snapshot(win);
  assert.equal(after.nodeCount, before.nodeCount, 'nodes');
  assert.equal(after.documentListeners, before.documentListeners, 'document listeners');
  assert.equal(after.windowListeners, before.windowListeners, 'window listeners');
  assert.equal(after.elementListeners, before.elementListeners, 'element listeners');
  assert.deepEqual(after.storageKeys, [], 'storage keys');
  assert.equal(win.setInterval, nativeSetInterval, 'setInterval restored');
  assert.equal(win.setTimeout, before.setTimeout, 'setTimeout untouched');
  assert.equal(win[api.CONTROLLER_KEY], undefined, 'controller removed');
  assert.equal(win.SessionWalkthroughTour, undefined, 'global API removed');
  assert.equal(win.document.getElementById(api.ROOT_ID), null);
  assert.equal(win.document.getElementById(api.STYLE_ID), null);
});

test('cleanup: re-injecting replaces the previous instance', async () => {
  const win = createWindow();
  pageWith(win, RECTS);
  const first = api.start(simpleTour(), { window: win });
  await first.ready();
  const second = api.start(simpleTour(), { window: win });
  await second.ready();
  assert.equal(first.status().open, false);
  assert.equal(win.document.querySelectorAll('#' + api.ROOT_ID).length, 1);
  assert.equal(win.document.querySelectorAll('#' + api.STYLE_ID).length, 1);
  assert.equal(win[api.CONTROLLER_KEY], second);
  second.close();
  assert.equal(win.document.querySelectorAll('#' + api.ROOT_ID).length, 0);
});

test('sessionStorage: the stored program restores the tour at the same step after a reload', async () => {
  const win = createWindow();
  pageWith(win, RECTS);
  // Stored tours must be self-contained: their source is re-evaluated after a reload.
  function selfContained() {
    return {
      id: 'simple',
      steps: [
        { id: 'one', title: 'One', target: '#a', quote: 'first line' },
        { id: 'two', title: 'Two', target: '#b', designDecision: 'chosen' }
      ]
    };
  }
  const c = api.start(selfContained, { window: win });
  await c.ready();
  await c.goTo(1);
  const record = api.readRecord(win.sessionStorage);
  assert.equal(record.tourId, 'simple');
  assert.equal(record.step, 1);
  assert.match(record.program, /sessionWalkthroughTourFactory/);

  // Simulate a full reload: a new window whose sessionStorage survived.
  const reloaded = createWindow();
  reloaded.sessionStorage = win.sessionStorage;
  pageWith(reloaded, RECTS);
  const context = vm.createContext({
    window: reloaded, globalThis: undefined, Promise, Date, Math, JSON, Object, Array, String, Number, Error, TypeError
  });
  context.globalThis = context;
  context.window = reloaded;
  context.document = reloaded.document;
  // The program assigns the API onto globalThis; point globalThis's window at the fake.
  const out = vm.runInContext(record.program, context);
  assert.equal(out, 'session-walkthrough tour restored');
  const restored = reloaded[api.CONTROLLER_KEY];
  assert.ok(restored, 'controller installed on the reloaded window');
  const st = await restored.ready();
  assert.equal(st.step, 2);
  assert.equal(st.stepId, 'two');
  restored.close();
  assert.equal(reloaded.sessionStorage.getItem(api.STORAGE_KEY), null, 'Close removes the key');
});

test('sessionStorage: a fresh start after Close begins at step 1', async () => {
  const win = createWindow();
  pageWith(win, RECTS);
  const c = api.start(simpleTour(), { window: win });
  await c.ready();
  await c.goTo(1);
  c.close();
  const again = api.start(simpleTour(), { window: win });
  assert.equal((await again.ready()).step, 1);
  again.close();
});

test('setInterval guard gates matching timers and restores the native function', async () => {
  const win = createWindow();
  const native = win.setInterval;
  const guard = api.installIntervalGuard(win, (fn) => fn.name === 'autoReload');
  assert.notEqual(win.setInterval, native);
  let reloads = 0;
  let others = 0;
  const a = win.setInterval(function autoReload() { reloads += 1; }, 5);
  const b = win.setInterval(function other() { others += 1; }, 5);
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(reloads, 0, 'matching interval paused');
  assert.ok(others > 0, 'other intervals run');
  assert.ok(guard.state.blocked > 0);
  assert.equal(guard.state.gated, 1);
  assert.equal(guard.restore(), true);
  assert.equal(win.setInterval, native, 'native setInterval restored');
  await new Promise((r) => setTimeout(r, 30));
  assert.ok(reloads > 0, 'gated interval resumes after restore');
  clearInterval(a);
  clearInterval(b);
});

test('setInterval guard: a stale wrapper is unwrapped to the native function', () => {
  const win = createWindow();
  const native = win.setInterval;
  api.installIntervalGuard(win, () => false); // lost instance never restored
  const second = api.installIntervalGuard(win, () => false);
  second.restore();
  assert.equal(win.setInterval, native);
});

test('runtime: guard.reArm runs once and the tour pauses the page timer', async () => {
  const win = createWindow();
  pageWith(win, RECTS);
  let ticks = 0;
  let timer = null;
  const reArm = () => {
    if (timer) clearInterval(timer);
    timer = win.setInterval(function pageReload() { ticks += 1; }, 5);
  };
  const c = api.start(simpleTour({ guard: { setInterval: (fn) => fn.name === 'pageReload', reArm } }), { window: win });
  await c.ready();
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(ticks, 0);
  assert.ok(c.status().guard.blocked > 0);
  c.close();
  await new Promise((r) => setTimeout(r, 30));
  assert.ok(ticks > 0);
  clearInterval(timer);
});

test('runtime: setup retries until the component is mounted, then poll finds the target', async () => {
  const win = createWindow();
  let attempts = 0;
  const tour = () => ({
    id: 'late',
    options: { pollInterval: 5 },
    steps: [{
      id: 'late', title: 'Late', quote: 'q', target: '#late',
      setup(ctx) {
        attempts += 1;
        if (attempts < 3) throw new Error('component not mounted');
        ctx.wait(20).then(() => pageWith(win, { late: { left: 10, top: 10, width: 50, height: 20 } }));
      },
      poll: { timeout: 500 }
    }]
  });
  const c = api.start(tour, { window: win });
  const st = await c.ready();
  assert.equal(attempts, 3);
  assert.equal(st.missing, false);
  assert.equal(st.error, '');
  c.close();
});

test('runtime: actions set controls, cannot submit, and re-render the step', async () => {
  const win = createWindow();
  const els = pageWith(win, RECTS);
  const form = win.document.createElement('form');
  win.document.body.appendChild(form);
  let submitted = 0;
  form.addEventListener('submit', () => { submitted += 1; });
  const tour = () => ({
    id: 'acts',
    steps: [{
      id: 'a', title: 'A', target: '#a', quote: 'q',
      body: () => 'value is ' + els.a.value,
      actions: [
        { label: 'Set', run: (ctx) => { ctx.setValue('#a', 'chosen'); } },
        { label: 'Bad', run: () => { form.dispatchEvent(new FakeEvent('submit', { bubbles: true })); } }
      ]
    }]
  });
  const c = api.start(tour, { window: win });
  await c.ready();
  const buttons = win.document.querySelector('.swt-actions').childNodes;
  buttons[0].click();
  await c.ready();
  assert.equal(els.a.value, 'chosen');
  assert.match(win.document.querySelector('.swt-body').textContent, /value is chosen/);
  win.document.querySelector('.swt-actions').childNodes[1].click();
  const st = await c.ready();
  assert.equal(submitted, 0, 'the submit was cancelled before the page saw it');
  assert.match(st.error, /submit during the action was cancelled/);
  c.close();
});

test('runtime: watch shows when the user save lands', async () => {
  const win = createWindow();
  pageWith(win, RECTS);
  const data = { revision: 1 };
  const tour = () => ({
    id: 'watch',
    steps: [{
      id: 'w', title: 'W', target: '#a', designDecision: 'd',
      watch: { interval: 5, check: () => (data.revision > 1 ? 'saved ' + data.revision : 'waiting') }
    }]
  });
  const c = api.start(tour, { window: win });
  assert.equal((await c.ready()).watch, 'waiting');
  data.revision = 2;
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(c.status().watch, 'saved 2');
  c.close();
});

test('runtime: the SPA navigation hook runs before a step with a route', async () => {
  const win = createWindow();
  pageWith(win, RECTS);
  const routes = [];
  const tour = () => ({
    id: 'spa',
    navigate: (ctx, route) => { routes.push(route); },
    steps: [
      { id: 'a', title: 'A', target: '#a', quote: 'q' },
      { id: 'b', title: 'B', target: '#b', quote: 'q', route: '/orders/1/tickets' }
    ]
  });
  const c = api.start(tour, { window: win });
  await c.ready();
  await c.goTo(1);
  assert.deepEqual(routes, ['/orders/1/tickets']);
  assert.ok(win.document.getElementById(api.ROOT_ID), 'overlay kept across the route change');
  c.close();
});

test('runtime: an invalid tour is refused before anything is added to the page', () => {
  const win = createWindow();
  const before = snapshot(win);
  assert.throws(() => api.start(() => ({ id: 'x', steps: [{ id: 'a', title: 'A' }] }), { window: win }), /invalid/);
  const after = snapshot(win);
  assert.equal(after.nodeCount, before.nodeCount);
  assert.deepEqual(after.storageKeys, []);
});
