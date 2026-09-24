# Shared-root template operating notes

`workspace-shared-root.json` has two root-scoped environment masters and no
unbound root orchestrator. Each master manages its own environment; neither has
authority for workspace installation, browser MCP configuration or shared-store
cleanup under the harness. Run `workspace install`,
`workspace browser-config --browser services` (or `vue3-services`) and the relevant
shared-store cleanup helpers from a user terminal outside the harness. Alternatively,
configure an unbound root orchestrator to own those operations. Do not unset or
edit launcher identity inside an active harness pane to bypass these restrictions.

If combining root-scoped and control-directory masters, routing is asymmetric:
a root-scoped master may address a control-directory master, but that confined
master can reply only via the unbound root orchestrator, when configured. Its
existing routing permissions do not include the root-scoped peer.
