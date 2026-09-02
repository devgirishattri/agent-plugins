# Schema-v4 Orchestration Configuration

`orchestration` is accepted only with `schema_version: 4`. Version 4 otherwise
retains schema-v3 harness and guard behavior; omitting `orchestration` leaves the
normalized plan and policy decision unchanged.

```json
{
  "schema_version": 4,
  "harness": {
    "enabled": true,
    "mode": "audit",
    "profile": "strict-v1",
    "roles": {
      "orchestrator": "master",
      "executor": "executor",
      "reviewer": "reviewer"
    },
    "gates": {
      "plan_review_ttl_minutes": 60,
      "audit_ttl_minutes": 60
    }
  },
  "orchestration": {
    "enabled": true,
    "profile": "reviewed-git-v1",
    "targets": [
      {
        "id": "component",
        "cwd": "component-a",
        "remote": "origin",
        "work_branch": "main",
        "release_branch": "production",
        "deploy": {
          "strategy": "merge-no-ff-v1",
          "align_work_after_release": true
        }
      }
    ]
  }
}
```

The omitted project/runtimes/roles/stores/sessions fields remain required. In
particular, `stores.pin` must include `messages` and `scheduler`.

Each target id is unique. Its safe relative `cwd` must exactly equal one
configured executor pane cwd and its one matching reviewer cwd, resolve to an
existing distinct child inside the project root, and be unique after physical
path resolution. Remote names cannot be URLs. Work/release refs are distinct,
safe literal Git refs.

The profile and deployment strategy are fixed enums. The alignment flag
defaults to false and can authorize only a post-release fast-forward. There are
no command, script, regex, free-form prompt, custom gate, or permission-bypass
fields. Use repository `AGENTS.md` for product-specific checks; use another
future reviewed profile when a different Git strategy is required.
