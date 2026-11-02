# Live tour example

A walkable example of the live tour mode. `demo.html` is a static, synthetic
order page with no network access and no framework. `demo-tour.js` is a
nine-step tour of a fictional client request:

> Add a Create Ticket action to the order menu, and move Company into the
> Associations panel. List the order's tickets with a status filter. Keep
> every line-item column; scroll sideways on narrow screens. Refunds stay
> admin-only.

Every name and figure on the page is invented.

## What it exercises

| Page feature | Tour feature |
|---|---|
| "⋮" order menu that gains Create Ticket | `setup` opens the menu through the page's own method |
| Company field that loads after a delay in the Associations panel | `setup` starts the load, `poll` waits for the field |
| Form with an unsaved-changes guard; Create Ticket disabled with a visible reason while dirty | "Design decision" step; action "Make the form dirty" sets a control only |
| Ticket list filtered by a field | Actions set the filter; body text reads the live count |
| 1800px line-item table in a horizontal scroller | Target clamped to its scroller and the viewport |
| Refund button hidden for the member role | `poll.hiddenReason` explains the missing target |
| Mock auto-refresh every 20 seconds | `guard.setInterval` pauses it; `guard.reArm` re-registers it |
| Save button | `watch` reports when the user's own save lands |

The last step lists what the tour did not show, with reasons.

## Way (a): chrome-devtools in the managed browser

This is how an agent runs a tour on a real app.

1. Open the page in a new tab with chrome-devtools `new_page`, using a
   `file://` URL to this directory's `demo.html`, for example
   `file:///<PLUGIN_ROOT>/examples/live-tour/demo.html`. If the browser
   refuses `file://` URLs, serve this directory with any static file server
   and open that URL instead.
2. Read the full text of `scripts/tour/overlay.js` and of `demo-tour.js`.
3. Call `evaluate_script` with one function that contains both, overlay first:

   ```js
   async () => {
     /* full text of scripts/tour/overlay.js */
     /* full text of examples/live-tour/demo-tour.js */
     return await SessionWalkthroughTour.whenReady();
   }
   ```

4. Dry-run: for each step `i` from 0 to 8, call
   `async () => SessionWalkthroughTour.goTo(i)` and check that the returned
   `overlaps` is false and `targetRect` matches the element. Step 7 (index 6)
   reports `missing: true` with the admin-only reason. That is expected.
5. Return to the start with `goTo(0)` and hand over.

To test recovery, reload the tab and run:

```js
() => (0, eval)(JSON.parse(sessionStorage.getItem('session-walkthrough-tour')).program)
```

The tour returns at the step it was on. Close (button, × or Esc) removes every
trace: run `() => [document.getElementById('session-walkthrough-tour-root'), sessionStorage.length, typeof SessionWalkthroughTour]`
and expect `[null, 0, "undefined"]`.

To check 67% zoom, set the browser zoom to 67% (`devicePixelRatio` about
0.667) and repeat the dry run. For a phone layout use `emulate` with a mobile
viewport, never `resize_page`, and reset it afterwards.

## Way (b): open it locally for manual testing

Open `demo.html?manual=1` in any browser, from this directory inside the
plugin. The page then loads `../../scripts/tour/overlay.js` and
`demo-tour.js` with script tags, and the tour starts. Reload the page to start
again after Close.

## Tests

`scripts/tour/tests/overlay.test.js` checks this tour as a fixture: every step
has a target and either a quote or a design decision, and the actions only set
controls. Run it with `node --test scripts/tour/tests/overlay.test.js` from the
plugin root, or run the whole plugin suite with
`bash scripts/test-session-walkthrough.sh`.
