# Live tour

A live tour is a self-driven walkthrough inside the browser the user already
has open. The orchestrating agent injects an overlay into the running app. The
overlay highlights each new or changed element and explains it in a small card.
The user clicks through it at their own pace.

This is the default meaning of "walk me through", "walkthrough", "tour" and
"show me the changes". It is not a set of screenshots, a recording or a
static screenshot page.

## Authority

- The orchestrating agent builds and runs the tour in the managed browser that
  is already running. Executors and reviewers do not drive it.
- The tour is read-mostly. It never commits, pushes or deploys, and never edits
  application code.
- Annotations exist only in the page DOM. Close removes them.
- Steps may set controls (choose a value, open a menu). They never submit or
  save. The user performs any real save themselves.
- Steps never discard or reset the form. The user's unsaved edits stay
  until the user saves or discards them.
- No remote service, telemetry, upload or video recording. No automatic replay
  of actions that change application state.

## Runtime

`scripts/tour/overlay.js` is dependency-free. The page cannot read local files,
so the agent passes the full overlay source and then the tour file source in
one chrome-devtools `evaluate_script` function:

```js
async () => {
  /* full text of scripts/tour/overlay.js */
  /* full text of the tour file, which calls SessionWalkthroughTour.start(...) */
  return await SessionWalkthroughTour.whenReady();
}
```

With chrome-devtools-mcp 1.11.0 or later, `evaluate_script` can also read a
file through `sourcePath` with `format: "script"`. This saves pasting the
overlay text. Inject `overlay.js`, then the tour file, in two such calls, and
then call `SessionWalkthroughTour.whenReady()`. The server accepts only paths
inside the client's workspace roots or the system temp directory. On an
"Access denied" error, paste the text as above.

The result is plain JSON: the current step, its target and card rectangles,
whether they overlap, the viewport and `devicePixelRatio`, and `styles`.
`styles` is `adopted` or `element` when the overlay's stylesheet applies, and
`blocked` when the page refused it. Other calls, each returning the same
status object:

| Call | Effect |
|---|---|
| `SessionWalkthroughTour.status()` | Current state and geometry, synchronous |
| `SessionWalkthroughTour.goTo(i)` | Show step `i` (from 0); resolves when it is ready |
| `SessionWalkthroughTour.next()` / `.prev()` | Move one step |
| `SessionWalkthroughTour.close()` | Close and remove everything |

The overlay adds one root (`#session-walkthrough-tour-root`) and one
stylesheet. The stylesheet is a constructed stylesheet in
`document.adoptedStyleSheets`, which a Content Security Policy `style-src`
does not block. Where constructed stylesheets are missing, it is a `<style>`
element that carries the page's nonce when the page has one. The root holds
the highlight ring and the card. The card shows a
title, a short body, and the quoted request line or a "Design decision" label.
It also shows "Step x of y", Previous, Next, Close and optional action
buttons. It is a
`role="dialog"` with an `aria-live` region that announces each step. Focus goes
to Next on start and returns to the previous element on Close. The keys are
←, → and Esc; arrow keys typed into a form field stay with the field. The
overlay never calls `alert`, `confirm` or `prompt`.

### Placement

The card is at most 350px wide. The target rectangle is first cut to its
scrolling containers and then clamped to the viewport, because wide tables
exceed both. The card goes below, above, right or left of the target, the
first side with room. Otherwise it goes to a corner, far bottom corner first,
choosing one that does not cover the target. When nothing fits, the overlay
scrolls the page once so the card fits below the target. Placement is
recomputed on scroll, resize (browser zoom included), page DOM changes and
the end of any CSS transition or animation. `status().overlaps` is true only
when the target is too large for any placement; author a smaller target then.

Before it places the card, the overlay waits until the target stops moving,
for at most `settleTimeout` (1000 ms). A menu that opens with a CSS transition
is measured when the transition ends, not halfway through. When a framework
re-creates the target node, the overlay queries the step's `target` again.

### Tour definition

A tour file wraps a self-contained factory. The factory's source is stored for
reload recovery, so it must not refer to variables outside itself.

```js
(function (root, defineTour) {
  if (typeof module === 'object' && module && module.exports) { module.exports = defineTour; return; }
  root.SessionWalkthroughTour.start(defineTour);
})(typeof globalThis !== 'undefined' ? globalThis : window, function myTour(api) {
  return {
    id: 'orders-create-ticket',
    title: 'Create Ticket action',
    guard: { setInterval: function (fn, delay) { return delay === 30000; }, reArm: function (ctx) {} },
    navigate: function (ctx, route) { /* optional SPA router push */ },
    onClose: function (ctx) { /* optional: undo what the tour itself set */ },
    steps: [ /* step objects */ ]
  };
});
```

`onClose` runs once when the tour closes, before the overlay removes itself.
It may close a menu the tour opened, or put back a value that an action set
while the control still holds that value. It never resets a whole form: a
form-wide discard also drops the edits the user made during the tour.

Step fields:

| Field | Meaning |
|---|---|
| `id`, `title` | Required. A unique id and a short title naming the new or changed element |
| `quote` or `designDecision` | Exactly one. The exact request line this step covers, or the reason for a choice the request did not make (shown as "Design decision") |
| `target` | Required. A selector, or `function (ctx)` returning an element. Re-queried on every step and after every action, because frameworks re-create nodes |
| `body` | A string, or `function (ctx)` that reads live page values. Never hard-code figures |
| `list` | Optional bullet items, or a function returning them |
| `setup` | `async function (ctx)`. Puts the page into the state the step explains through adapter hooks, such as the page component's own methods. Retried until it stops throwing or `setupTimeout` passes, so it can wait for a component to mount. Re-run after each action, so keep it idempotent |
| `poll` | A timeout in ms, or `{ timeout, interval, hiddenReason }`. Waits for a visible target. If none appears, the card says why, using `hiddenReason` (for example "hidden for this role") |
| `actions` | `[{ label, run(ctx) }]`. Buttons that only set controls. A form submit during an action is cancelled and reported |
| `watch` | `{ interval, check(ctx) }`. Polls page data and shows the returned text, for example when the user's own save has landed |
| `route` | Optional. Passed to the tour's `navigate` hook before the step, so one tour can span client-side routes |

`ctx` gives `window`, `document`, `$`, `$$`, `text(selector)`, `wait(ms)`,
`poll(fn, opts)`, `setValue(target, value)` (sets the value and fires `input`
and `change`), `click(target)` (only to open a menu or tab), `navigate(route)`,
`index`, `total` and `state` (an object kept per step for the whole tour).

### Adapter hooks

The core has no framework code. Reach a component through the page itself.
For Vue 2, find the component instance through `el.__vue__` and call its
methods. Vue 2 sets `__vue__` in production builds too.

```js
function vm(ctx, selector) {
  var el = ctx.$(selector);
  while (el && !el.__vue__) el = el.parentElement;
  if (!el) throw new Error('component not mounted yet');
  // On a root element shared with a parent (the app root, a wrapper),
  // el.__vue__ is the outermost instance. Step down to the one that renders el.
  var inst = el.__vue__;
  for (var i = 0; i < inst.$children.length; i++) {
    if (inst.$children[i].$el === el) { inst = inst.$children[i]; i = -1; }
  }
  return inst;
}
// setup: function (ctx) { vm(ctx, '.order-view').openActionsMenu(); }
```

Throwing from `setup` while the component is not mounted makes the overlay
retry.

### Resilience

- **Reload.** On first injection the overlay stores the tour program and the
  current step in `sessionStorage` under `session-walkthrough-tour`. After a
  full reload, re-inject with one line:
  `() => (0, eval)(JSON.parse(sessionStorage.getItem('session-walkthrough-tour')).program)`.
  Close removes the key.
- **Content Security Policy.** The reload line also works on pages whose
  policy has no `'unsafe-eval'` or requires Trusted Types. Code run by
  chrome-devtools `evaluate_script` can call `eval` there. If another
  tool reports an `EvalError`, repeat the first injection (overlay, then tour
  file). The tour resumes at the stored step. A `style-src` without
  `'unsafe-inline'` blocks inline `<style>` elements, so the overlay uses a
  constructed stylesheet (see [Runtime](#runtime)).
- **Auto-reload timers.** `guard.setInterval` is a predicate over
  `(fn, delay)`. While the tour is open the overlay wraps `window.setInterval`,
  and matching intervals do nothing. Only intervals registered after injection
  are gated. `guard.reArm(ctx)` runs once after the wrap so the page can
  re-register its timer, for example through a component method. Close
  restores the native `setInterval` and lets gated timers run again.
- **SPA routes.** The overlay root survives client-side navigation. Steps with
  `route` call the tour's `navigate` hook (for example a router push) first.
- **Re-injection** replaces the previous instance and resumes at its step.

### Cleanup

Close (button, × or Esc) removes every node, listener, stylesheet, observer
and storage key the overlay added, restores every wrapped global, and removes
the `SessionWalkthroughTour` global.

## Authoring a tour

- Put every change to a field value behind an action button, so the user
  chooses it. `setup` opens menus, tabs and panels, and leaves field values
  as they are. Never call the page's discard or reset from a step.
- Each step names the new or changed element. It quotes the exact line of the
  client request it covers, or carries a "Design decision" when the request
  was silent.
- Order the steps:
  1. overview;
  2. each changed surface;
  3. blocked or disabled states;
  4. the result;
  5. a final "Not shown" step that lists anything not demonstrated, with
     reasons.
- Prefer synthetic or demo records. When only real data exists, choose records
  without personal contact details. Never write customer data into a tour file
  saved to disk; read values from the page at run time instead.
- A step with `route` leaves the current view. The framework re-creates its
  components, which drops unsaved edits, including the user's own. Put route
  steps before the step that asks the user to save. Keep that step on the
  page where the save happens.

## Procedure

Preconditions:

1. The managed browser and the app server are already running. Never start,
   restart or replace either. If one is down, ask the user.
2. The session is authorized. Otherwise mark role-gated steps "not verified".
3. Open a fresh ordinary tab with `new_page`. Never navigate a tab the user is
   working in.
4. Read `window.innerWidth` and `window.devicePixelRatio`. For phone layouts
   use `emulate`, never `resize_page`, and reset the emulation afterwards.

Build and check:

1. Write the tour file in the agent's scratch area, outside the app
   repository.
2. Inject the overlay and the tour with one `evaluate_script` call, or by
   `sourcePath` (see [Runtime](#runtime)).
3. Dry-run every step with `goTo(i)`:
   - Check that `styles` is not `blocked`. If it is, close the tour and tell
     the user that the page's policy refused the overlay's styles.
   - Check placement with `evaluate_script` geometry: the returned
     `targetRect`, `cardRect` and `overlaps`, or `getBoundingClientRect()` of
     the target and the card. The card must lie inside the viewport. Do not
     use element-scoped screenshots: they crop the wrong rectangle when
     `devicePixelRatio` is not 1 (browser zoom other than 100%).
   - Confirm that the right element is highlighted and that missing targets
     explain why.
4. Confirm that no save happened: the network request list shows only GET
   requests, and the page data is unchanged.
5. Return to step 1 with `goTo(0)`.

Hand over:

1. Tell the user the tour is ready in the new tab, and how to move (Next,
   Previous, ←, →, Esc).
2. Once the user starts clicking, stop driving the tab: no navigation, no
   re-injection over their work. Re-inject only when the user asks, for
   example after a reload.
3. Optionally write a short local note listing the steps, the records used and
   the unverified items.

## Example

`examples/live-tour/` has a synthetic demo page and a nine-step tour that
exercises every feature. Its README explains both ways to run it.
