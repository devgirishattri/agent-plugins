# gh credentials and read grants for child panes

This is guidance for project owners who configure executor and reviewer panes.
It adds no grant, permission or config of its own. Some points below are owner
requirements rather than checks the harness enforces; each section says which.

## Choose each pane's gh credential at launch (H3)

Owner requirements:

1. Do not switch credentials per command (for example with a
   `GH_CONFIG_DIR=…` prefix). This guidance grants no exemption for credential
   overrides. Whether strict-v1 refuses a given form depends on the role and on
   the operand scope, so do not rely on a refusal to enforce this.
2. Declare the credential's environment key, such as `GH_TOKEN`, in the
   workspace config's `secrets` block. `secrets.allow` names the admitted
   environment keys; `secrets.visible_to_roles` and per-key roles control which
   panes receive the key. Never put a token value in the config. The launcher
   injects the value; agents never export it.
3. Scope the token itself on GitHub: read-only, limited to the repositories
   the pane works on. Exposing a key to a role does not narrow what the token
   can do.
4. Run gh as a bare literal command with an explicit repository, for example
   `gh run list --repo OWNER/NAME`.

Limits:

- Passing the harness check does not prove that the provider sandbox, network
  access or a native approval prompt will allow the call.
- A missing or unusable credential must be reported as "unavailable". Never
  substitute an executor-reported result for an independent check.
- Reviewer access to gh is not enabled by this page. A restricted reviewer gh
  grammar is planned separately.

## `read_paths` grant reading, not running (H7)

Enforced by strict-v1: a pane's `read_paths` (see the main skill, "Read
grants") lets that pane read the listed files and directories, and does not
let it execute a script from them. `bash <granted script>` or
`python3 <granted script>` stays refused even when the file is readable.
Protected stores, provider homes, secrets and other environments cannot be
granted.

Owner requirements:

- Copying a readable script into the checkout grants nothing by itself. A
  reviewed in-checkout copy still needs the pane's normal execution
  authorization and must meet the bounds in
  [verifier-capability.md](verifier-capability.md).
- Do not move the work to the orchestrator as a substitute executor.

Rollback: this page is documentation only. Removing it changes no behavior.
