/*
 * session-walkthrough live tour overlay.
 *
 * Dependency-free. The orchestrating agent injects this file's full source,
 * followed by a tour definition file, through chrome-devtools evaluate_script.
 * The page cannot read local files, so both sources travel inside the injected
 * function. See skills/session-walkthrough/references/live-tour.md.
 *
 * The overlay is read-mostly: it highlights elements and explains them. It
 * never submits, saves, navigates away or edits application code. Close
 * removes every node, listener, style and storage key it added and restores
 * every global it wrapped.
 *
 * In Node (tests) the module exports its API and touches no globals.
 */
(function (root, factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module && module.exports) {
    module.exports = api;
  } else if (root) {
    root.SessionWalkthroughTour = api;
  }
})(typeof globalThis !== 'undefined' ? globalThis : typeof window !== 'undefined' ? window : this,
function sessionWalkthroughTourFactory() {
  'use strict';

  var VERSION = '0.2.0';
  var STORAGE_KEY = 'session-walkthrough-tour';
  var CONTROLLER_KEY = '__sessionWalkthroughTour';
  var GLOBAL_KEY = 'SessionWalkthroughTour';
  var ROOT_ID = 'session-walkthrough-tour-root';
  var STYLE_ID = 'session-walkthrough-tour-style';
  var NATIVE_MARK = '__sessionWalkthroughNative';
  var DEFAULTS = {
    cardMaxWidth: 350,
    gap: 12,
    margin: 8,
    ringPadding: 4,
    pollTimeout: 3000,
    pollInterval: 100,
    setupTimeout: 4000,
    watchInterval: 1000
  };

  // ---------------------------------------------------------------------------
  // Pure helpers (unit-tested in Node)
  // ---------------------------------------------------------------------------

  function num(value, fallback) {
    return typeof value === 'number' && isFinite(value) ? value : fallback;
  }

  function between(value, low, high) {
    if (high < low) return low;
    return Math.min(Math.max(value, low), high);
  }

  function edges(rect) {
    if (!rect) return null;
    var left = num(rect.left, num(rect.x, 0));
    var top = num(rect.top, num(rect.y, 0));
    var width = num(rect.width, num(rect.right, left) - left);
    var height = num(rect.height, num(rect.bottom, top) - top);
    return { left: left, top: top, right: left + width, bottom: top + height };
  }

  // Intersect a rectangle with the viewport. Wide scrolling tables and tall
  // panels exceed the viewport, so every placement starts from this.
  function clampRect(rect, viewport) {
    var e = edges(rect);
    if (!e || !viewport) return null;
    var left = Math.max(0, e.left);
    var top = Math.max(0, e.top);
    var right = Math.min(viewport.width, e.right);
    var bottom = Math.min(viewport.height, e.bottom);
    if (!(right > left) || !(bottom > top)) return null;
    return { left: left, top: top, right: right, bottom: bottom, width: right - left, height: bottom - top };
  }

  function inflateRect(rect, by) {
    var e = edges(rect);
    if (!e) return null;
    return {
      left: e.left - by, top: e.top - by,
      width: e.right - e.left + 2 * by, height: e.bottom - e.top + 2 * by
    };
  }

  function rectsOverlap(a, b) {
    var x = edges(a), y = edges(b);
    if (!x || !y) return false;
    return x.left < y.right && y.left < x.right && x.top < y.bottom && y.top < x.bottom;
  }

  function cardWidthFor(viewport, maxWidth, margin) {
    var m = num(margin, DEFAULTS.margin);
    return Math.max(0, Math.min(num(maxWidth, DEFAULTS.cardMaxWidth), viewport.width - 2 * m));
  }

  // Choose where the card goes. Inputs: the target's bounding rectangle (or
  // null when the target is missing), the viewport size and the card size.
  // Output: { side, corner, left, top, width, height, target, overlaps }.
  // Sides are tried in order (below, above, right, left) and the first one
  // with room wins. Otherwise the card goes to a corner, far bottom first, and
  // the first corner that does not cover the target wins.
  function computePlacement(targetRect, viewport, card, options) {
    options = options || {};
    var margin = num(options.margin, DEFAULTS.margin);
    var gap = num(options.gap, DEFAULTS.gap);
    var padding = num(options.padding, 0);
    var vw = viewport.width, vh = viewport.height;
    var w = Math.max(0, Math.min(card.width, vw - 2 * margin));
    var h = Math.max(0, card.height);
    var t = targetRect ? clampRect(inflateRect(targetRect, padding), viewport) : null;

    function box(left, top) {
      return { left: left, top: top, right: left + w, bottom: top + h, width: w, height: h };
    }
    function result(side, corner, left, top) {
      var b = box(left, top);
      return {
        side: side, corner: corner, left: left, top: top, width: w, height: h,
        target: t, overlaps: t ? rectsOverlap(b, t) : false
      };
    }

    if (t) {
      var sides = {
        below: function () {
          if (vh - margin - (t.bottom + gap) < h || h > vh - 2 * margin) return null;
          return [between(t.left, margin, vw - margin - w), t.bottom + gap];
        },
        above: function () {
          if (t.top - gap - margin < h || h > vh - 2 * margin) return null;
          return [between(t.left, margin, vw - margin - w), t.top - gap - h];
        },
        right: function () {
          if (vw - margin - (t.right + gap) < w || h > vh - 2 * margin) return null;
          return [t.right + gap, between(t.top, margin, vh - margin - h)];
        },
        left: function () {
          if (t.left - gap - margin < w || h > vh - 2 * margin) return null;
          return [t.left - gap - w, between(t.top, margin, vh - margin - h)];
        }
      };
      var order = options.order || ['below', 'above', 'right', 'left'];
      for (var i = 0; i < order.length; i++) {
        var pick = sides[order[i]] && sides[order[i]]();
        if (pick && !rectsOverlap(box(pick[0], pick[1]), t)) {
          return result(order[i], null, pick[0], pick[1]);
        }
      }
    }

    var leftX = margin, rightX = Math.max(margin, vw - margin - w);
    var topY = margin, bottomY = Math.max(margin, vh - margin - h);
    var targetOnRight = t ? (t.left + t.right) / 2 >= vw / 2 : false;
    var far = targetOnRight ? ['bottom-left', leftX] : ['bottom-right', rightX];
    var near = targetOnRight ? ['bottom-right', rightX] : ['bottom-left', leftX];
    var corners = [
      [far[0], far[1], bottomY],
      [near[0], near[1], bottomY],
      [far[0].replace('bottom', 'top'), far[1], topY],
      [near[0].replace('bottom', 'top'), near[1], topY]
    ];
    for (var c = 0; c < corners.length; c++) {
      if (!t || !rectsOverlap(box(corners[c][1], corners[c][2]), t)) {
        return result('corner', corners[c][0], corners[c][1], corners[c][2]);
      }
    }
    return result('corner', corners[0][0], corners[0][1], corners[0][2]);
  }

  // When no side has room and the card would cover the target, return how far
  // to scroll the page vertically so the card fits below the target. Returns 0
  // when no scroll is needed and null when the target is too tall to fit
  // beside any card (author a smaller target then).
  function fitScrollDelta(targetRect, viewport, card, options) {
    options = options || {};
    if (!targetRect) return 0;
    var placement = computePlacement(targetRect, viewport, card, options);
    if (!placement.overlaps) return 0;
    var margin = num(options.margin, DEFAULTS.margin);
    var gap = num(options.gap, DEFAULTS.gap);
    var e = edges(inflateRect(targetRect, num(options.padding, 0)));
    var height = e.bottom - e.top;
    if (height > viewport.height - 2 * margin - gap - card.height) return null;
    var desiredTop = viewport.height - margin - card.height - gap - height - 1;
    return e.top - desiredTop;
  }

  // Step navigation state machine. State: { index, total, closed }.
  function navReduce(state, action) {
    var next = { index: state.index, total: state.total, closed: !!state.closed };
    if (next.closed || !action) return next;
    var last = Math.max(0, next.total - 1);
    switch (action.type) {
      case 'next':
        if (next.index < last) next.index += 1;
        break;
      case 'prev':
        if (next.index > 0) next.index -= 1;
        break;
      case 'goto':
        next.index = between(Math.floor(num(action.index, next.index)), 0, last);
        break;
      case 'finish':
      case 'close':
        next.closed = true;
        break;
      default:
        break;
    }
    return next;
  }

  function keyToAction(key) {
    if (key === 'ArrowRight' || key === 'Right') return { type: 'next' };
    if (key === 'ArrowLeft' || key === 'Left') return { type: 'prev' };
    if (key === 'Escape' || key === 'Esc') return { type: 'close' };
    return null;
  }

  function isNonEmptyString(value) {
    return typeof value === 'string' && value.trim() !== '';
  }

  // Structural checks for a tour definition. Returns a list of problems.
  function validateTour(tour) {
    var problems = [];
    if (!tour || typeof tour !== 'object') return ['tour definition is not an object'];
    if (!isNonEmptyString(tour.id)) problems.push('tour.id must be a non-empty string');
    if (!Array.isArray(tour.steps) || tour.steps.length === 0) {
      problems.push('tour.steps must be a non-empty array');
      return problems;
    }
    var seen = {};
    tour.steps.forEach(function (step, i) {
      var label = 'step ' + (i + 1);
      if (!step || typeof step !== 'object') { problems.push(label + ' is not an object'); return; }
      if (!isNonEmptyString(step.id)) problems.push(label + ': id must be a non-empty string');
      else if (seen[step.id]) problems.push(label + ': duplicate id ' + step.id);
      else seen[step.id] = true;
      if (!isNonEmptyString(step.title)) problems.push(label + ': title must be a non-empty string');
      if (!isNonEmptyString(step.target) && typeof step.target !== 'function') {
        problems.push(label + ': target must be a selector or a function');
      }
      var hasQuote = isNonEmptyString(step.quote);
      var hasDecision = isNonEmptyString(step.designDecision);
      if (hasQuote === hasDecision) {
        problems.push(label + ': needs exactly one of quote or designDecision');
      }
      if (step.body !== undefined && typeof step.body !== 'string' && typeof step.body !== 'function') {
        problems.push(label + ': body must be a string or a function');
      }
      if (step.setup !== undefined && typeof step.setup !== 'function') {
        problems.push(label + ': setup must be a function');
      }
      if (step.actions !== undefined) {
        if (!Array.isArray(step.actions)) problems.push(label + ': actions must be an array');
        else step.actions.forEach(function (action, j) {
          if (!action || !isNonEmptyString(action.label) || typeof action.run !== 'function') {
            problems.push(label + ': action ' + (j + 1) + ' needs a label and a run function');
          }
        });
      }
      if (step.watch !== undefined && (!step.watch || typeof step.watch.check !== 'function')) {
        problems.push(label + ': watch needs a check function');
      }
    });
    if (tour.guard !== undefined && tour.guard !== null) {
      if (tour.guard.setInterval !== undefined && typeof tour.guard.setInterval !== 'function') {
        problems.push('guard.setInterval must be a predicate function');
      }
    }
    if (tour.navigate !== undefined && typeof tour.navigate !== 'function') {
      problems.push('navigate must be a function');
    }
    return problems;
  }

  function unwrapNative(fn) {
    return fn && fn[NATIVE_MARK] ? fn[NATIVE_MARK] : fn;
  }

  // Wrap win.setInterval so that intervals matching the predicate do nothing
  // while the tour is open. Only intervals registered after installation are
  // gated; a tour's guard.reArm hook asks the page to re-register its timer.
  function installIntervalGuard(win, predicate) {
    var native = unwrapNative(win.setInterval);
    var state = { paused: true, blocked: 0, gated: 0, restored: false };
    function guardedSetInterval(fn) {
      var args = Array.prototype.slice.call(arguments, 2);
      var match = false;
      try {
        match = typeof fn === 'function' && !!predicate(fn, arguments[1]);
      } catch (error) {
        match = false;
      }
      if (!match) return native.apply(win, arguments);
      state.gated += 1;
      return native.call(win, function () {
        if (state.paused) { state.blocked += 1; return undefined; }
        return fn.apply(this, args);
      }, arguments[1]);
    }
    guardedSetInterval[NATIVE_MARK] = native;
    win.setInterval = guardedSetInterval;
    return {
      state: state,
      restore: function () {
        state.paused = false;
        if (win.setInterval === guardedSetInterval) {
          win.setInterval = native;
          state.restored = true;
        }
        return state.restored;
      }
    };
  }

  // The program stored in sessionStorage. Evaluating it after a full reload
  // rebuilds the overlay and resumes the tour at the stored step.
  function buildProgram(factorySource, tourSource) {
    return '(function(f,t){var a=f();' +
      "(typeof globalThis!=='undefined'?globalThis:window)." + GLOBAL_KEY + '=a;' +
      'a.start(t,{resume:true});return "session-walkthrough tour restored";})(' +
      factorySource + ',' + tourSource + ');';
  }

  function readRecord(storage) {
    try {
      var raw = storage && storage.getItem(STORAGE_KEY);
      if (!raw) return null;
      var record = JSON.parse(raw);
      return record && typeof record === 'object' ? record : null;
    } catch (error) {
      return null;
    }
  }

  function resolveText(value, ctx) {
    if (value === undefined || value === null) return '';
    if (typeof value === 'function') {
      try {
        var out = value(ctx);
        return out === undefined || out === null ? '' : String(out);
      } catch (error) {
        return '(value unavailable: ' + (error && error.message ? error.message : String(error)) + ')';
      }
    }
    return String(value);
  }

  function resolveList(value, ctx) {
    if (typeof value === 'function') {
      try { value = value(ctx); } catch (error) { return ['(list unavailable: ' + error.message + ')']; }
    }
    return Array.isArray(value) ? value.map(String) : [];
  }

  function isEditable(el) {
    if (!el || !el.tagName) return false;
    var tag = String(el.tagName).toUpperCase();
    return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || !!el.isContentEditable;
  }

  function plainRect(rect) {
    if (!rect) return null;
    var e = edges(rect);
    return {
      left: Math.round(e.left * 10) / 10, top: Math.round(e.top * 10) / 10,
      width: Math.round((e.right - e.left) * 10) / 10, height: Math.round((e.bottom - e.top) * 10) / 10
    };
  }

  // ---------------------------------------------------------------------------
  // Runtime
  // ---------------------------------------------------------------------------

  var STYLE_TEXT = [
    '#' + ROOT_ID + '{position:fixed;left:0;top:0;width:0;height:0;z-index:2147483000;pointer-events:none;',
    'font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:#0f172a}',
    '#' + ROOT_ID + ' *{box-sizing:border-box}',
    '#' + ROOT_ID + ' .swt-ring{position:fixed;border:3px solid #2563eb;border-radius:6px;',
    'box-shadow:0 0 0 4px rgba(37,99,235,.25);pointer-events:none}',
    '#' + ROOT_ID + ' .swt-card{position:fixed;pointer-events:auto;background:#fff;color:#0f172a;',
    'border:1px solid #cbd5e1;border-radius:10px;box-shadow:0 12px 32px rgba(15,23,42,.28);',
    'padding:12px 14px;max-height:calc(100vh - 16px);overflow:auto;outline:none;text-align:left}',
    '#' + ROOT_ID + ' .swt-card:focus-visible{box-shadow:0 0 0 3px rgba(37,99,235,.5),0 12px 32px rgba(15,23,42,.28)}',
    '#' + ROOT_ID + ' .swt-head{display:flex;align-items:center;justify-content:space-between;gap:8px;',
    'font-size:12px;color:#475569;margin-bottom:4px}',
    '#' + ROOT_ID + ' .swt-title{font-size:16px;font-weight:600;margin:0 0 6px;line-height:1.3}',
    '#' + ROOT_ID + ' .swt-label{display:inline-block;font-size:11px;font-weight:600;letter-spacing:.02em;',
    'text-transform:uppercase;color:#1d4ed8;background:#dbeafe;border-radius:4px;padding:1px 6px;margin-bottom:4px}',
    '#' + ROOT_ID + ' .swt-label[data-kind="design"]{color:#92400e;background:#fef3c7}',
    '#' + ROOT_ID + ' .swt-quote{margin:0 0 8px;padding:4px 8px;border-left:3px solid #93c5fd;color:#334155;font-style:italic}',
    '#' + ROOT_ID + ' .swt-decision{margin:0 0 8px;color:#334155}',
    '#' + ROOT_ID + ' .swt-body{margin:0 0 8px}',
    '#' + ROOT_ID + ' .swt-list{margin:0 0 8px;padding-left:18px}',
    '#' + ROOT_ID + ' .swt-note{margin:0 0 8px;padding:6px 8px;border-radius:6px;background:#fef2f2;color:#991b1b}',
    '#' + ROOT_ID + ' .swt-status{margin:0 0 8px;padding:6px 8px;border-radius:6px;background:#f0fdf4;color:#166534}',
    '#' + ROOT_ID + ' .swt-actions{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 8px}',
    '#' + ROOT_ID + ' .swt-nav{display:flex;justify-content:flex-end;gap:6px}',
    '#' + ROOT_ID + ' button{font:inherit;font-size:13px;border-radius:6px;border:1px solid #cbd5e1;',
    'background:#f8fafc;color:#0f172a;padding:4px 10px;cursor:pointer;margin:0}',
    '#' + ROOT_ID + ' button:disabled{opacity:.45;cursor:default}',
    '#' + ROOT_ID + ' button.swt-primary{background:#2563eb;border-color:#2563eb;color:#fff}',
    '#' + ROOT_ID + ' button.swt-x{border:none;background:transparent;font-size:16px;line-height:1;padding:2px 6px}',
    '#' + ROOT_ID + ' .swt-sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}',
    '@media (prefers-color-scheme: dark){',
    '#' + ROOT_ID + ' .swt-card{background:#0f172a;color:#e2e8f0;border-color:#334155}',
    '#' + ROOT_ID + ' .swt-head{color:#94a3b8}',
    '#' + ROOT_ID + ' .swt-quote,#' + ROOT_ID + ' .swt-decision{color:#cbd5e1}',
    '#' + ROOT_ID + ' button{background:#1e293b;color:#e2e8f0;border-color:#334155}',
    '#' + ROOT_ID + ' button.swt-primary{background:#2563eb;border-color:#2563eb;color:#fff}}'
  ].join('');

  function resolveEnv(options) {
    var g = typeof globalThis !== 'undefined' ? globalThis : {};
    var win = options.window || g.window || g;
    var doc = options.document || win.document;
    var storage = options.storage;
    if (storage === undefined) {
      try { storage = win.sessionStorage; } catch (error) { storage = null; }
    }
    return { win: win, doc: doc, storage: storage || null };
  }

  function removeStale(doc) {
    [ROOT_ID, STYLE_ID].forEach(function (id) {
      var node = doc.getElementById && doc.getElementById(id);
      if (node && node.parentNode) node.parentNode.removeChild(node);
    });
  }

  function start(defineTour, options) {
    options = options || {};
    if (typeof defineTour !== 'function') {
      throw new TypeError('start(defineTour): defineTour must be a function that returns the tour');
    }
    var env = resolveEnv(options);
    var record = readRecord(env.storage);
    var previous = env.win[CONTROLLER_KEY];
    if (previous && typeof previous.close === 'function') {
      try { previous.close({ replaced: true }); } catch (error) { /* replaced anyway */ }
    }
    removeStale(env.doc);
    var tour = defineTour(api);
    var problems = validateTour(tour);
    if (problems.length) throw new Error('Tour definition is invalid: ' + problems.join('; '));
    var startIndex = 0;
    if (typeof options.startAt === 'number') {
      startIndex = options.startAt;
    } else if (options.resume !== false && record && record.tourId === tour.id && typeof record.step === 'number') {
      startIndex = record.step;
    }
    var controller = createController(env, tour, defineTour, options);
    env.win[CONTROLLER_KEY] = controller;
    controller.begin(startIndex);
    return controller;
  }

  function createController(env, tour, defineTour, options) {
    var win = env.win, doc = env.doc, storage = env.storage;
    var cfg = {};
    Object.keys(DEFAULTS).forEach(function (key) {
      cfg[key] = num(tour.options && tour.options[key], DEFAULTS[key]);
    });
    var timers = {
      setTimeout: unwrapNative(win.setTimeout),
      clearTimeout: unwrapNative(win.clearTimeout),
      setInterval: unwrapNative(win.setInterval),
      clearInterval: unwrapNative(win.clearInterval)
    };
    var listeners = [];
    var pendingTimeouts = [];
    var state = { index: 0, total: tour.steps.length, closed: false };
    var token = 0;
    var guard = null;
    var watchId = null;
    var stepState = {};
    var current = { target: null, missing: false, reason: '', error: '', placement: null, status: '' };
    var previousFocus = doc.activeElement || null;
    var nodes = {};
    var readyWaiters = [];
    var showing = null;
    var busy = false;
    var repositionQueued = false;
    var program = null;
    try {
      program = buildProgram('(' + sessionWalkthroughTourFactory.toString() + ')', '(' + defineTour.toString() + ')');
    } catch (error) {
      program = null;
    }

    function listen(target, type, fn, opts) {
      target.addEventListener(type, fn, opts);
      listeners.push([target, type, fn, opts]);
    }

    function later(fn, ms) {
      var id = timers.setTimeout.call(win, function () {
        var at = pendingTimeouts.indexOf(id);
        if (at >= 0) pendingTimeouts.splice(at, 1);
        fn();
      }, ms);
      pendingTimeouts.push(id);
      return id;
    }

    function sleep(ms) {
      return new Promise(function (resolve) { later(resolve, ms); });
    }

    function now() {
      return Date.now();
    }

    async function poll(fn, opts) {
      opts = opts || {};
      var timeout = num(opts.timeout, cfg.pollTimeout);
      var interval = Math.max(10, num(opts.interval, cfg.pollInterval));
      var deadline = now() + timeout;
      var my = token;
      for (;;) {
        var value = null;
        try { value = await fn(); } catch (error) { value = null; }
        if (value) return value;
        if (state.closed || my !== token || now() >= deadline) return null;
        await sleep(interval);
      }
    }

    async function retry(fn, timeout) {
      var deadline = now() + timeout;
      var my = token;
      var lastError = null;
      for (;;) {
        try {
          await fn();
          return { ok: true };
        } catch (error) {
          lastError = error;
        }
        if (state.closed || my !== token || now() >= deadline) return { ok: false, error: lastError };
        await sleep(cfg.pollInterval);
      }
    }

    function element(target) {
      if (!target) return null;
      if (typeof target === 'string') {
        try { return doc.querySelector(target); } catch (error) { return null; }
      }
      return target;
    }

    function makeCtx(step) {
      var id = step.id;
      if (!stepState[id]) stepState[id] = {};
      return {
        window: win,
        document: doc,
        api: api,
        tour: tour,
        step: step,
        index: state.index,
        total: state.total,
        state: stepState[id],
        $: function (selector) { return element(selector); },
        $$: function (selector) {
          try { return Array.prototype.slice.call(doc.querySelectorAll(selector)); } catch (error) { return []; }
        },
        text: function (selector) {
          var el = element(selector);
          return el ? String(el.textContent || '').trim() : '';
        },
        wait: sleep,
        poll: poll,
        // Actions may only set controls: a value, a checkbox, an open menu.
        setValue: function (target, value) {
          var el = element(target);
          if (!el) throw new Error('setValue: no element for ' + String(target));
          if (typeof value === 'boolean' && 'checked' in el) el.checked = value;
          else el.value = value;
          ['input', 'change'].forEach(function (type) {
            el.dispatchEvent(new win.Event(type, { bubbles: true }));
          });
          return el;
        },
        click: function (target) {
          var el = element(target);
          if (!el) throw new Error('click: no element for ' + String(target));
          el.click();
          return el;
        },
        navigate: function (route) {
          if (typeof tour.navigate !== 'function') throw new Error('this tour has no navigate hook');
          return tour.navigate(makeCtx(step), route);
        }
      };
    }

    function resolveTarget(step, ctx) {
      try {
        return element(typeof step.target === 'function' ? step.target(ctx) : step.target);
      } catch (error) {
        return null;
      }
    }

    function visible(el) {
      if (!el || el.isConnected === false || typeof el.getBoundingClientRect !== 'function') return false;
      var rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    }

    // The target's rectangle cut down to what its scrolling ancestors show.
    // A wide table inside an overflow container is clipped to the container.
    function visibleRectOf(el) {
      var e = edges(el.getBoundingClientRect());
      if (typeof win.getComputedStyle === 'function') {
        for (var node = el.parentElement; node && node !== doc.body && node !== doc.documentElement; node = node.parentElement) {
          var cs = win.getComputedStyle(node);
          var clipX = /(auto|scroll|hidden|clip)/.test(cs.overflowX);
          var clipY = /(auto|scroll|hidden|clip)/.test(cs.overflowY);
          if (!clipX && !clipY) continue;
          var c = edges(node.getBoundingClientRect());
          if (clipX) { e.left = Math.max(e.left, c.left); e.right = Math.min(e.right, c.right); }
          if (clipY) { e.top = Math.max(e.top, c.top); e.bottom = Math.min(e.bottom, c.bottom); }
        }
      }
      return { left: e.left, top: e.top, width: Math.max(0, e.right - e.left), height: Math.max(0, e.bottom - e.top) };
    }

    function viewport() {
      return { width: win.innerWidth, height: win.innerHeight };
    }

    function make(tag, className, text) {
      var el = doc.createElement(tag);
      if (className) el.className = className;
      if (text !== undefined) el.textContent = text;
      return el;
    }

    function buildDom() {
      var style = make('style');
      style.id = STYLE_ID;
      style.textContent = STYLE_TEXT;
      (doc.head || doc.documentElement || doc.body).appendChild(style);

      var root = make('div');
      root.id = ROOT_ID;
      root.setAttribute('data-session-walkthrough', 'tour');

      var ring = make('div', 'swt-ring');
      ring.setAttribute('aria-hidden', 'true');
      ring.style.display = 'none';

      var live = make('div', 'swt-sr');
      live.setAttribute('aria-live', 'polite');
      live.setAttribute('aria-atomic', 'true');

      var card = make('div', 'swt-card');
      card.setAttribute('role', 'dialog');
      card.setAttribute('aria-modal', 'false');
      card.setAttribute('aria-labelledby', 'swt-title');
      card.setAttribute('aria-describedby', 'swt-body');
      card.setAttribute('tabindex', '-1');
      card.style.left = '-10000px';
      card.style.top = '0px';

      var head = make('div', 'swt-head');
      var counter = make('span', 'swt-counter');
      var closeX = make('button', 'swt-x', '×');
      closeX.type = 'button';
      closeX.setAttribute('aria-label', 'Close tour');
      head.appendChild(counter);
      head.appendChild(closeX);

      var title = make('h2', 'swt-title');
      title.id = 'swt-title';
      var label = make('span', 'swt-label');
      var quote = make('blockquote', 'swt-quote');
      var decision = make('p', 'swt-decision');
      var body = make('p', 'swt-body');
      body.id = 'swt-body';
      var list = make('ul', 'swt-list');
      var note = make('p', 'swt-note');
      note.setAttribute('role', 'note');
      var status = make('p', 'swt-status');
      var actions = make('div', 'swt-actions');
      var nav = make('div', 'swt-nav');
      var prev = make('button', '', 'Previous');
      prev.type = 'button';
      var next = make('button', 'swt-primary', 'Next');
      next.type = 'button';
      var close = make('button', '', 'Close');
      close.type = 'button';
      nav.appendChild(prev);
      nav.appendChild(next);
      nav.appendChild(close);

      [head, title, label, quote, decision, body, list, note, status, actions, nav].forEach(function (child) {
        card.appendChild(child);
      });
      root.appendChild(ring);
      root.appendChild(card);
      root.appendChild(live);
      doc.body.appendChild(root);

      listen(prev, 'click', function () { dispatch({ type: 'prev' }); });
      listen(next, 'click', function () {
        dispatch(state.index >= state.total - 1 ? { type: 'finish' } : { type: 'next' });
      });
      listen(close, 'click', function () { dispatch({ type: 'close' }); });
      listen(closeX, 'click', function () { dispatch({ type: 'close' }); });

      nodes = {
        style: style, root: root, ring: ring, live: live, card: card, counter: counter, title: title,
        label: label, quote: quote, decision: decision, body: body, list: list, note: note,
        status: status, actions: actions, prev: prev, next: next, close: close
      };
    }

    function show(el, on) {
      el.style.display = on ? '' : 'none';
    }

    function clear(el) {
      while (el.firstChild) el.removeChild(el.firstChild);
    }

    function renderCard(step, ctx, preparing) {
      if (!nodes.card) return;
      nodes.counter.textContent = 'Step ' + (state.index + 1) + ' of ' + state.total;
      nodes.title.textContent = step.title;
      if (step.quote) {
        nodes.label.textContent = 'Request';
        nodes.label.setAttribute('data-kind', 'request');
        nodes.quote.textContent = '“' + step.quote + '”';
        show(nodes.quote, true);
        show(nodes.decision, false);
      } else {
        nodes.label.textContent = 'Design decision';
        nodes.label.setAttribute('data-kind', 'design');
        nodes.decision.textContent = step.designDecision;
        show(nodes.decision, true);
        show(nodes.quote, false);
      }
      nodes.body.textContent = preparing ? 'Preparing this step…' : resolveText(step.body, ctx);
      show(nodes.body, nodes.body.textContent !== '');

      clear(nodes.list);
      var items = preparing ? [] : resolveList(step.list, ctx);
      items.forEach(function (item) { nodes.list.appendChild(make('li', '', item)); });
      show(nodes.list, items.length > 0);

      var noteText = '';
      if (!preparing && current.missing) noteText = 'Not shown here: ' + current.reason;
      if (!preparing && current.error) noteText = (noteText ? noteText + ' ' : '') + current.error;
      nodes.note.textContent = noteText;
      show(nodes.note, noteText !== '');

      nodes.status.textContent = current.status;
      show(nodes.status, current.status !== '');

      clear(nodes.actions);
      var actions = preparing ? [] : step.actions || [];
      actions.forEach(function (action) {
        var button = make('button', '', action.label);
        button.type = 'button';
        listen(button, 'click', function () { runAction(step, action); });
        nodes.actions.appendChild(button);
      });
      show(nodes.actions, actions.length > 0);

      nodes.prev.disabled = state.index === 0;
      nodes.next.textContent = state.index >= state.total - 1 ? 'Finish' : 'Next';
    }

    function position() {
      if (state.closed || !nodes.card) return;
      if (nodes.root.isConnected === false && doc.body) doc.body.appendChild(nodes.root);
      var vp = viewport();
      var width = cardWidthFor(vp, cfg.cardMaxWidth, cfg.margin);
      nodes.card.style.width = width + 'px';
      var measured = nodes.card.getBoundingClientRect();
      var size = { width: width, height: Math.max(1, num(measured && measured.height, 0)) };
      var target = current.target;
      if (target && target.isConnected === false) {
        var step = tour.steps[state.index];
        target = resolveTarget(step, makeCtx(step));
        current.target = visible(target) ? target : null;
        target = current.target;
      }
      var rect = target ? visibleRectOf(target) : null;
      if (rect && !(rect.width > 0 && rect.height > 0)) rect = null;
      var placement = computePlacement(rect, vp, size, {
        gap: cfg.gap, margin: cfg.margin, padding: cfg.ringPadding
      });
      current.placement = placement;
      if (placement.target) {
        nodes.ring.style.left = placement.target.left + 'px';
        nodes.ring.style.top = placement.target.top + 'px';
        nodes.ring.style.width = placement.target.width + 'px';
        nodes.ring.style.height = placement.target.height + 'px';
        show(nodes.ring, true);
      } else {
        show(nodes.ring, false);
      }
      nodes.card.style.left = placement.left + 'px';
      nodes.card.style.top = placement.top + 'px';
    }

    // Scroll the page once so the card can sit beside the target.
    function fitTarget() {
      if (state.closed || !nodes.card || !current.target || typeof win.scrollBy !== 'function') return;
      var vp = viewport();
      var width = cardWidthFor(vp, cfg.cardMaxWidth, cfg.margin);
      nodes.card.style.width = width + 'px';
      var measured = nodes.card.getBoundingClientRect();
      var size = { width: width, height: Math.max(1, num(measured && measured.height, 0)) };
      var delta = fitScrollDelta(visibleRectOf(current.target), vp, size, {
        gap: cfg.gap, margin: cfg.margin, padding: cfg.ringPadding
      });
      if (delta) {
        try { win.scrollBy({ top: delta, left: 0, behavior: 'instant' }); } catch (error) { /* ignore */ }
      }
    }

    function queueReposition() {
      if (repositionQueued || state.closed) return;
      repositionQueued = true;
      var raf = win.requestAnimationFrame ? function (fn) { return win.requestAnimationFrame(fn); }
        : function (fn) { return later(fn, 16); };
      raf(function () {
        repositionQueued = false;
        position();
      });
    }

    function stopWatch() {
      if (watchId !== null) {
        timers.clearInterval.call(win, watchId);
        watchId = null;
      }
    }

    function startWatch(step, ctx) {
      stopWatch();
      if (!step.watch) return;
      var my = token;
      var tick = function () {
        if (state.closed || my !== token) return;
        var text = '';
        try {
          var out = step.watch.check(ctx);
          text = out && typeof out === 'object' ? String(out.text || '') : out ? String(out) : '';
        } catch (error) {
          text = '(watch unavailable: ' + error.message + ')';
        }
        if (text !== current.status) {
          current.status = text;
          nodes.status.textContent = text;
          show(nodes.status, text !== '');
          nodes.body.textContent = resolveText(step.body, ctx);
          position();
        }
      };
      tick();
      watchId = timers.setInterval.call(win, tick, num(step.watch.interval, cfg.watchInterval));
    }

    function persist() {
      if (!storage || !program) return;
      try {
        storage.setItem(STORAGE_KEY, JSON.stringify({
          version: 1, tourId: tour.id, step: state.index, program: program
        }));
      } catch (error) { /* storage full or blocked: recovery unavailable */ }
    }

    function announce(step) {
      nodes.live.textContent = 'Step ' + (state.index + 1) + ' of ' + state.total + ': ' + step.title;
    }

    function settle() {
      busy = false;
      var snapshot = status();
      var waiters = readyWaiters;
      readyWaiters = [];
      waiters.forEach(function (resolve) { resolve(snapshot); });
    }

    async function prepare(step, ctx, my) {
      current = { target: null, missing: false, reason: '', error: '', placement: null, status: '' };
      if (step.route !== undefined && typeof tour.navigate === 'function') {
        try { await tour.navigate(ctx, step.route); } catch (error) {
          current.error = 'Navigation did not complete: ' + error.message;
        }
        if (my !== token) return false;
      }
      if (typeof step.setup === 'function') {
        var outcome = await retry(function () { return step.setup(ctx); }, num(step.setupTimeout, cfg.setupTimeout));
        if (my !== token) return false;
        if (!outcome.ok) {
          current.error = 'Setup did not complete: ' + (outcome.error && outcome.error.message ? outcome.error.message : 'unknown error') + '.';
        }
      }
      var pollCfg = typeof step.poll === 'number' ? { timeout: step.poll }
        : step.poll && typeof step.poll === 'object' ? step.poll : {};
      var found = await poll(function () {
        var el = resolveTarget(step, ctx);
        return visible(el) ? el : null;
      }, pollCfg);
      if (my !== token) return false;
      if (found) {
        current.target = found;
        var rect = found.getBoundingClientRect();
        var vp = viewport();
        if ((rect.top < 0 || rect.bottom > vp.height || rect.left < 0 || rect.left >= vp.width) &&
            typeof found.scrollIntoView === 'function') {
          try { found.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (error) { /* ignore */ }
        }
      } else {
        current.missing = true;
        var timeout = num(pollCfg.timeout, cfg.pollTimeout);
        current.reason = resolveText(pollCfg.hiddenReason, ctx) ||
          'the target did not appear within ' + Math.round(timeout / 100) / 10 + ' seconds.';
      }
      return true;
    }

    async function showStep(index) {
      var my = ++token;
      busy = true;
      stopWatch();
      state = navReduce(state, { type: 'goto', index: index });
      var step = tour.steps[state.index];
      persist();
      var ctx = makeCtx(step);
      current.status = '';
      renderCard(step, ctx, true);
      position();
      if (!(await prepare(step, ctx, my))) return;
      renderCard(step, ctx, false);
      fitTarget();
      position();
      announce(step);
      startWatch(step, ctx);
      settle();
    }

    function go(index) {
      if (state.closed) return Promise.resolve(status());
      showing = showStep(index);
      return showing.then(function () { return status(); });
    }

    async function runAction(step, action) {
      if (state.closed) return;
      var my = token;
      busy = true;
      var blocked = 0;
      var stopSubmit = function (event) {
        blocked += 1;
        event.preventDefault();
        if (event.stopImmediatePropagation) event.stopImmediatePropagation();
      };
      doc.addEventListener('submit', stopSubmit, true);
      var ctx = makeCtx(step);
      var failure = '';
      try {
        await action.run(ctx);
      } catch (error) {
        failure = 'The action "' + action.label + '" did not complete: ' + error.message;
      } finally {
        doc.removeEventListener('submit', stopSubmit, true);
      }
      if (state.closed || my !== token) return;
      // Re-run setup and re-query the target: the page may have re-rendered.
      var keepStatus = current.status;
      if (!(await prepare(step, ctx, my))) return;
      current.status = keepStatus;
      if (blocked) failure += (failure ? ' ' : '') + 'A form submit during the action was cancelled; tours never submit.';
      if (failure) current.error = (current.error ? current.error + ' ' : '') + failure;
      renderCard(step, ctx, false);
      fitTarget();
      position();
      startWatch(step, ctx);
      settle();
    }

    function dispatch(action) {
      if (state.closed) return;
      var next = navReduce(state, action);
      if (next.closed) { close(); return; }
      if (next.index !== state.index) go(next.index);
    }

    function onKey(event) {
      if (state.closed || event.defaultPrevented) return;
      if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
      var action = keyToAction(event.key);
      if (!action) return;
      var inCard = nodes.root && nodes.root.contains && nodes.root.contains(event.target);
      if (!inCard && isEditable(event.target)) return;
      event.preventDefault();
      dispatch(action);
    }

    function status() {
      var step = tour.steps[state.index];
      var targetRect = null, cardRect = null, overlaps = false;
      if (!state.closed && nodes.card) {
        cardRect = plainRect(nodes.card.getBoundingClientRect());
        if (current.target && current.target.isConnected !== false) {
          var clamped = clampRect(visibleRectOf(current.target), viewport());
          targetRect = plainRect(clamped);
          overlaps = clamped ? rectsOverlap(cardRect, clamped) : false;
        }
      }
      return {
        version: VERSION,
        tourId: tour.id,
        open: !state.closed,
        step: state.index + 1,
        total: state.total,
        stepId: step ? step.id : null,
        title: step ? step.title : null,
        missing: current.missing,
        reason: current.reason,
        error: current.error,
        watch: current.status,
        side: current.placement ? current.placement.side : null,
        corner: current.placement ? current.placement.corner : null,
        overlaps: overlaps,
        targetRect: targetRect,
        cardRect: cardRect,
        viewport: { width: win.innerWidth, height: win.innerHeight, devicePixelRatio: win.devicePixelRatio || 1 },
        guard: guard ? { gated: guard.state.gated, blocked: guard.state.blocked } : null
      };
    }

    function close(opts) {
      if (state.closed) return status();
      opts = opts || {};
      var ctx = makeCtx(tour.steps[state.index]);
      state = navReduce(state, { type: 'close' });
      token += 1;
      stopWatch();
      if (typeof tour.onClose === 'function') {
        try { tour.onClose(ctx); } catch (error) { /* cleanup continues */ }
      }
      pendingTimeouts.splice(0).forEach(function (id) { timers.clearTimeout.call(win, id); });
      listeners.splice(0).forEach(function (entry) {
        entry[0].removeEventListener(entry[1], entry[2], entry[3]);
      });
      if (guard) { guard.restore(); }
      [nodes.root, nodes.style].forEach(function (node) {
        if (node && node.parentNode) node.parentNode.removeChild(node);
      });
      removeStale(doc);
      nodes = {};
      if (storage) {
        try { storage.removeItem(STORAGE_KEY); } catch (error) { /* ignore */ }
      }
      if (win[CONTROLLER_KEY] === controller) {
        try { delete win[CONTROLLER_KEY]; } catch (error) { win[CONTROLLER_KEY] = undefined; }
      }
      if (!opts.replaced && options.keepGlobal !== true && win[GLOBAL_KEY]) {
        try { delete win[GLOBAL_KEY]; } catch (error) { win[GLOBAL_KEY] = undefined; }
      }
      if (!opts.replaced && previousFocus && previousFocus.isConnected !== false &&
          typeof previousFocus.focus === 'function') {
        try { previousFocus.focus(); } catch (error) { /* ignore */ }
      }
      settle();
      return status();
    }

    function begin(startIndex) {
      buildDom();
      listen(doc, 'keydown', onKey, true);
      listen(win, 'resize', queueReposition);
      listen(win, 'scroll', queueReposition, true);
      if (tour.guard && typeof tour.guard.setInterval === 'function') {
        guard = installIntervalGuard(win, tour.guard.setInterval);
        if (typeof tour.guard.reArm === 'function') {
          try { tour.guard.reArm(makeCtx(tour.steps[0])); } catch (error) { /* page may not support it */ }
        }
      }
      go(startIndex);
      if (nodes.next && typeof nodes.next.focus === 'function') {
        try { nodes.next.focus(); } catch (error) { /* ignore */ }
      }
    }

    var controller = {
      begin: begin,
      close: close,
      status: status,
      goTo: function (index) { return go(index); },
      next: function () { return go(Math.min(state.index + 1, state.total - 1)); },
      prev: function () { return go(Math.max(state.index - 1, 0)); },
      // Resolves when the current step is ready; at once when nothing is pending.
      ready: function () {
        if (state.closed || !busy) return Promise.resolve(status());
        return new Promise(function (resolve) { readyWaiters.push(resolve); });
      },
      dispatch: dispatch,
      tour: tour
    };
    return controller;
  }

  function activeController(win) {
    var g = typeof globalThis !== 'undefined' ? globalThis : {};
    var w = win || g.window || g;
    return w[CONTROLLER_KEY] || null;
  }

  function closed() {
    return { open: false };
  }

  var api = {
    VERSION: VERSION,
    STORAGE_KEY: STORAGE_KEY,
    CONTROLLER_KEY: CONTROLLER_KEY,
    GLOBAL_KEY: GLOBAL_KEY,
    ROOT_ID: ROOT_ID,
    STYLE_ID: STYLE_ID,
    DEFAULTS: DEFAULTS,
    clampRect: clampRect,
    inflateRect: inflateRect,
    rectsOverlap: rectsOverlap,
    cardWidthFor: cardWidthFor,
    computePlacement: computePlacement,
    fitScrollDelta: fitScrollDelta,
    navReduce: navReduce,
    keyToAction: keyToAction,
    validateTour: validateTour,
    installIntervalGuard: installIntervalGuard,
    buildProgram: buildProgram,
    readRecord: readRecord,
    start: start,
    // Convenience calls for evaluate_script. Each returns plain JSON.
    status: function (win) { var c = activeController(win); return c ? c.status() : closed(); },
    whenReady: function (win) { var c = activeController(win); return c ? c.ready() : Promise.resolve(closed()); },
    goTo: function (index, win) { var c = activeController(win); return c ? c.goTo(index) : Promise.resolve(closed()); },
    next: function (win) { var c = activeController(win); return c ? c.next() : Promise.resolve(closed()); },
    prev: function (win) { var c = activeController(win); return c ? c.prev() : Promise.resolve(closed()); },
    close: function (win) { var c = activeController(win); return c ? c.close() : closed(); }
  };
  return api;
});
