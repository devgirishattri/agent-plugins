# Build receipts and freshness

A capture shows the application that was running. A receipt binds that
running target to the source it was built from. `build.freshness` records how
strong that binding is. Matching source hashes alone never bind a running
target; the binding below does.

## Receipt shape

| Field | Meaning |
|---|---|
| `kind` | `web-build-info`, `native-build` or `authorized-build-output` |
| `source.revision` | The commit the build reports; required |
| `source.fingerprint` | The dirty-tree fingerprint the build reports, or `null` when it knows only the commit |
| `binding` | How the running target was tied to that build: `origin` or `installed` (below) |
| `reference` | Optional pointer: product path, task-contract receipt id, workflow run |
| `recorded_at` | When the receipt was observed |

The manifest stores observed values only. Receipt configuration never contains
an executable shell string; it names a declared endpoint path or an existing
authorized build result.

## Bindings

| Binding | Proves | Fields |
|---|---|---|
| `origin` | The selected origin served its own build info from a declared, bounded path | `origin` (must equal `target.identity.origin`), `path` |
| `installed` | The product the adapter built is the product installed on the selected target | `identity` (the target's `udid`, `device` or `bundle_id` keys), `product_sha256`, `installed_sha256` read back from the installed target, or `null` when it was not read back |

`web-build-info` requires `origin`. `native-build` requires `installed`.
`authorized-build-output` accepts either, because the existing authorized
workflow must still say which running target it produced
(`WT-RECEIPT-BINDING`). A receipt whose binding names a different origin,
device or bundle than the captured target contradicts the capture; it cannot
bless it.

## Derived freshness

`WT-BUILD-FRESHNESS` derives the value in this order. The declared
`build.freshness` must equal it.

| Order | Condition | Freshness |
|---|---|---|
| 1 | `receipt` is `null` | `unverified` |
| 2 | Binding violates `WT-RECEIPT-BINDING`; or a non-null `installed_sha256` differs from `product_sha256`; or `source.revision` differs from `repository.head_end`; or a non-null `source.fingerprint` differs from `scope.end.fingerprint` | `contradicted`; validation fails (`WT-BUILD-CONTRADICTED`) |
| 3 | `installed` binding with `installed_sha256: null` | `unverified` (the running product was not read back; a valid, honest state) |
| 4 | `source.fingerprint` is `null` and `scope.end.entries` is non-empty | `verified-commit-only` |
| 5 | Otherwise | `verified` |

## Unbound paths

`build.unbound_paths` is derived, never free text (`WT-BUILD-UNBOUND`):

| Freshness | `unbound_paths` |
|---|---|
| `verified-commit-only` | Every `scope.end.entries` path: the commit is bound, the dirty working tree is not |
| `verified` | Every end entry with `omitted` set: a matching fingerprint cannot verify bytes it never hashed |
| other | Empty |

The report shows the freshness label verbatim and lists these paths under it.

## What is not proof

Process start times, PIDs, file modification times and server uptime can
suggest staleness. They cannot prove freshness. Record them as limitations,
never as a receipt. A fingerprint match with omitted entries binds only the
hashed files. A commit-only receipt binds the commit, not the edits on top of
it.
