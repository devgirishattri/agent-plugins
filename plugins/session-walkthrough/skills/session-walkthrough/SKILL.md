---
name: session-walkthrough
description: Live, self-driven walkthrough tour of a session's application changes in the already-running managed browser. Use for any request to walk the user through a change ("walk me through", "walkthrough", "tour", "show me the changes", or /session-walkthrough). The tour is an overlay the user clicks through; it is read-mostly, never saves, and makes no recording.
---

# session-walkthrough

After a coding session, walk the user through what changed in the running
application with a live tour. A live tour is an overlay injected into the app
in the browser that is already running. It highlights each new or changed
element and explains it in a small card that quotes the request line it
covers. The user clicks through it.

The contract, the step shape and the full procedure are in
[references/live-tour.md](references/live-tour.md). A walkable example is in
`${CLAUDE_PLUGIN_ROOT}/examples/live-tour/`.

Every walkthrough request means the live tour. Never answer one with
screenshots, a recording or an improvised static screenshot page. This plugin
makes no recordings. When the user asks for a recorded walkthrough or an
evidence bundle, say that the plugin offers only the live tour and offer it.

## Authority

- The orchestrating agent builds and runs the tour in the managed browser that
  is already running. Executors and reviewers do not drive it.
- The tour is read-mostly. It never commits, pushes or deploys, and never edits
  application code.
- Annotations live only in the page DOM. Close removes them.
- Tour actions only set controls. The user performs any real save themselves.
- A tour never discards or resets the user's unsaved edits.

## Procedure

The orchestrating agent follows these steps.

1. Check the preconditions. The managed browser and the app server must
   already run. Never start, restart or replace either; if one is down, ask the
   user. The session must be authorized; otherwise mark role-gated steps "not
   verified".
2. Open a fresh ordinary tab with chrome-devtools `new_page`. Never navigate a
   tab the user is working in.
3. Read `window.innerWidth` and `window.devicePixelRatio`. For phone layouts
   use `emulate`, never `resize_page`, and reset it afterwards.
4. Write the tour file in your scratch area, with one step per new or changed
   element. Each step quotes its request line or is labelled "Design decision".
   Order: overview, changed surfaces, blocked or disabled states, the result,
   and a final "Not shown" step. Prefer synthetic or demo records; never write
   customer data into the file.
5. Read the full text of the overlay and the tour file. Inject both, overlay
   first, in one `evaluate_script` function. The overlay is at:

   ```
   ${CLAUDE_PLUGIN_ROOT}/scripts/tour/overlay.js
   ```

6. Dry-run every step with `SessionWalkthroughTour.goTo(i)`. Check that the
   returned `styles` is not `blocked`. Check placement with the returned
   geometry (`targetRect`, `cardRect`, `overlaps`) or
   `getBoundingClientRect()`, not element-scoped screenshots. Confirm that no
   save happened: only GET requests in the network list, page data unchanged.
   Return to step 1.
7. Hand over. Once the user starts clicking, stop driving the tab: no
   navigation and no re-injection over their work.
8. Optionally write a short local note with the steps, the records used and
   the unverified items.
