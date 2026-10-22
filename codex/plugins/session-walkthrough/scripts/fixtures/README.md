# Synthetic walkthrough fixtures

Contract inputs for the manifest validator and renderer. Everything here is
synthetic: placeholder project, paths, hashes and media. No real application
was captured.

| Path | Contents |
|---|---|
| `run/assets/before.png`, `run/assets/after.png` | 4×4 solid PNGs generated deterministically |
| `run/assets/clip-stub.mp4` | Header-only MP4 (valid `ftyp` and empty `mdat` boxes). It satisfies hash, containment and signature checks. It is not playable and is not a caption-playback fixture. |
| `manifests/valid-*.json` | Complete valid manifests: web stills with an out-of-scope observed change; macOS window with a captioned clip and a commit-only receipt; the same with the installed product not read back (`unverified`); hostile text that must render as plain text; a partial run without a baseline; a clean-to-clean run whose only change was committed between the snapshots; the same with an empty endpoint diff; and dirty-tree transitions (dirty→committed, dirty→restored as `unknown`, a real deletion) |
| `manifests/<rule>.json` | One negative per validation rule, each a minimal mutation of its control |
| `manifests/index.json` | Expected outcome per file: `valid`, or `invalid` with the `WT-*` codes the validator must report, plus the control file |

`duplicate-json-key.json` is hand-formed text: a serializer cannot emit it.

Validate a fixture with the run directory `run/` and the manifest path given
separately; run-directory mode (`manifest.json` inside `<run-id>/`) applies to
real runs only. The real `file://` caption playback test needs an actual
recorded clip and a browser; it is pilot evidence, not a fixture.
