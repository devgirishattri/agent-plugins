/*
 * Example live tour for examples/live-tour/demo.html.
 *
 * Fictional client request covered by this tour:
 *   "Add a Create Ticket action to the order menu, and move Company into the
 *    Associations panel. List the order's tickets with a status filter. Keep
 *    every line-item column; scroll sideways on narrow screens. Refunds stay
 *    admin-only."
 *
 * In a browser this file starts the tour with the overlay that was injected
 * just before it. In Node it exports the tour factory for the fixture tests.
 * The factory is self-contained: its source is stored in sessionStorage for
 * reload recovery, so it must not refer to anything outside itself.
 */
(function (root, defineTour) {
  'use strict';
  if (typeof module === 'object' && module && module.exports) {
    module.exports = defineTour;
    return;
  }
  if (!root.SessionWalkthroughTour) {
    throw new Error('Inject scripts/tour/overlay.js before demo-tour.js');
  }
  root.SessionWalkthroughTour.start(defineTour);
})(typeof globalThis !== 'undefined' ? globalThis : window, function demoTour(api) {
  'use strict';

  // Adapter hook: reach the page's own component methods. The demo exposes
  // them on window.demoApp; a Vue 2 app would use el.__vue__ (see live-tour.md).
  function app(ctx) {
    var found = ctx.window.demoApp;
    if (!found) throw new Error('demo page is not ready yet');
    return found;
  }

  return {
    id: 'demo-order-ticket-and-company',
    title: 'Create Ticket action and Company move',
    // Pause the page's mock auto-refresh while the tour is open. reArm asks
    // the page to re-register its timer so the wrapped setInterval sees it.
    guard: {
      setInterval: function (fn) { return fn && fn.name === 'autoRefreshTick'; },
      reArm: function (ctx) { app(ctx).restartAutoRefresh(); }
    },
    steps: [
      {
        id: 'overview',
        title: 'What changed on the order page',
        quote: 'Add a Create Ticket action to the order menu, and move Company into the Associations panel.',
        target: '#order-header',
        body: function (ctx) {
          return 'This tour walks through ' + ctx.total + ' steps on order ' +
            ctx.text('#order-header h1').replace('Order ', '') +
            '. The page’s auto-refresh is paused while the tour is open. Use ← and → to move, Esc to close.';
        }
      },
      {
        id: 'create-ticket-action',
        title: 'New: Create Ticket in the ⋮ menu',
        quote: 'Add a Create Ticket action to the order menu',
        target: '#action-create-ticket-row',
        setup: function (ctx) { app(ctx).openMenu(); },
        body: 'The order actions menu now ends with Create Ticket. The tour opened the menu for you; nothing was clicked inside it.'
      },
      {
        id: 'company-in-associations',
        title: 'Company moved into Associations',
        quote: 'move Company into the Associations panel',
        target: '#company-field',
        setup: function (ctx) {
          app(ctx).closeMenu();
          app(ctx).loadAssociations();
        },
        poll: { timeout: 4000 },
        body: function (ctx) {
          var value = ctx.$('#company-field') ? ctx.$('#company-field').value : '';
          return 'Company now lives in the Associations panel, which loads a moment after it opens. Current value: ' +
            (value || 'No company') + '.';
        },
        actions: [
          {
            label: 'Choose a sample company',
            // Sets a control only. Saving is left to the user.
            run: function (ctx) {
              var select = ctx.$('#company-field');
              var options = ctx.$$('#company-field option');
              ctx.setValue(select, options.length > 1 ? options[1].value : '');
            }
          }
        ]
      },
      {
        id: 'create-ticket-disabled',
        title: 'Create Ticket waits for unsaved changes',
        designDecision: 'The request did not say what happens with unsaved edits. Create Ticket is disabled, with a visible reason, while the form has unsaved changes, so a ticket never captures half-edited data.',
        target: '#action-create-ticket-row',
        setup: function (ctx) { app(ctx).openMenu(); },
        body: function (ctx) {
          return app(ctx).isDirty()
            ? 'The form has unsaved changes right now, so the action is disabled and says why.'
            : 'The form is clean right now, so the action is enabled. Use the button below to make the form dirty and see the disabled state.';
        },
        actions: [
          {
            label: 'Make the form dirty',
            run: function (ctx) {
              ctx.setValue('#field-notes', (ctx.$('#field-notes').value || '') + ' (tour edit)');
            }
          }
        ]
      },
      {
        id: 'ticket-filter',
        title: 'Tickets with a status filter',
        quote: 'List the order’s tickets with a status filter.',
        target: '#ticket-panel',
        setup: function (ctx) { app(ctx).closeMenu(); },
        body: function (ctx) {
          var counts = app(ctx).ticketCounts();
          return 'The filter narrows the list in place. It shows ' + counts.shown + ' of ' + counts.total + ' tickets now.';
        },
        actions: [
          { label: 'Show open only', run: function (ctx) { ctx.setValue('#ticket-filter', 'open'); } },
          { label: 'Show all', run: function (ctx) { ctx.setValue('#ticket-filter', 'all'); } }
        ]
      },
      {
        id: 'line-items-scroll',
        title: 'Line items keep every column',
        quote: 'Keep every line-item column; scroll sideways on narrow screens.',
        target: '#line-items-table',
        body: function (ctx) {
          var columns = ctx.$$('#line-items-table th').length;
          return 'All ' + columns + ' columns stay; the table scrolls sideways inside its panel instead of dropping columns.';
        }
      },
      {
        id: 'refund-admin-only',
        title: 'Refund stays admin-only',
        quote: 'Refunds stay admin-only.',
        target: '#admin-refund',
        poll: {
          timeout: 1500,
          hiddenReason: function (ctx) {
            return 'Refund order is shown only to admins. This session is signed in as ' +
              app(ctx).role + ', so the button stays hidden. Not verified for the admin role.';
          }
        },
        body: 'This step explains an element that this session cannot see.'
      },
      {
        id: 'result-save',
        title: 'The result: you save',
        designDecision: 'Company saves with the rest of the order through the existing Save button. The tour never saves; press Save yourself when you want to keep a change.',
        target: '#save-button',
        setup: function (ctx) {
          if (ctx.state.revision === undefined) ctx.state.revision = app(ctx).data.revision;
        },
        body: 'Press Save to keep any change you made in this tour, or Discard to drop it.',
        watch: {
          interval: 500,
          check: function (ctx) {
            var data = app(ctx).data;
            return data.revision > ctx.state.revision
              ? 'Your save landed: revision ' + data.revision + ', company ' + (data.company || 'none') + '.'
              : 'Waiting for your save. Nothing has been saved by the tour.';
          }
        }
      },
      {
        id: 'not-shown',
        title: 'Not shown',
        designDecision: 'Anything this tour could not demonstrate is listed here with the reason.',
        target: '#order-header',
        setup: function (ctx) { app(ctx).closeMenu(); },
        body: 'These parts were not demonstrated:',
        list: [
          'The ticket form that Create Ticket opens: it is outside this change.',
          'Refund order for admins: this session is a member.',
          'Saving: the tour never saves, so persistence is shown only if you saved in the previous step.'
        ]
      }
    ]
  };
});
