# TODO

## session-chat Plugin Enhancements

- [ ] `/broadcast` — Send a message to all named sessions at once
  - Context: identified during plugin review session
  - Priority: medium

- [ ] `/dispatch-all` — Dispatch same task to multiple sessions
  - Context: identified during plugin review session
  - Priority: low

## session-context Plugin Enhancements

- [ ] Auto-attach context snapshots during `/dispatch`
  - Context: manual context generation, listing, loading, and sharing commands exist; automatic attachment is still future work
  - Priority: medium

## New Plugins

- [ ] Prompt Templates plugin
  - Context: orchestrator repeatedly types similar dispatch prompts
  - Priority: medium

- [ ] Session Dashboard plugin
  - Context: single-command view of all sessions and their status
  - Priority: low

## Provider Support

- [ ] Keep Claude and Codex plugin command parity in sync
  - Context: this repo now publishes provider-specific plugin trees
  - Priority: high

- [ ] Add release checklist for Claude and Codex marketplace metadata
  - Context: each provider has its own manifest and marketplace file
  - Priority: medium
