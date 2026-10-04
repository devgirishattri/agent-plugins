#!/usr/bin/env python3
"""Offline positive/negative controls for every native grader under evals/.

No model call. Each grader's input_match / pattern is applied to JSON-serialized
tool inputs (exactly what the native runner matches) and compared with an
expected verdict. Coverage is enforced: a tool_used/regex grader with no control
entry, or one whose controls lack both a matching and a non-matching string,
fails the run. Also checks min/max sanity and portable case.json invariants.
Usage: python3 -B evals/test-graders.py
"""
import json, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
K = '/x/knowledge/0.5.1/scripts/'
J = lambda tool, inp: (tool, json.dumps(inp))
B = lambda cmd: J('Bash', {'command': cmd})
W = lambda p, c='x': J('Write', {'file_path': p, 'content': c})
E = lambda p, o='a', n='b': J('Edit', {'file_path': p, 'old_string': o, 'new_string': n})
R = lambda p: J('Read', {'file_path': p})
SK = lambda s: J('Skill', {'skill': s})
M = lambda s: ('msg', s)  # last-message string for regex graders

GUARDED = [
    (B(f'bash "{K}memory-write.sh" apply --store s --target t.md'), True),
    (B(f'bash "{K}memory-write.sh" --store s capture --staged x'), True),
    (B(f'bash "{K}save-context.sh" n f'), True),
    (B(f'bash "{K}remove-context.sh" n'), True),
    (B(f'bash "{K}memory-auto-capture.sh" --staged /t/a.md'), True),
    (B(f'bash "{K}memory-remember.sh" --store s --staged /t/a.md'), True),
    (B(f'bash "{K}memory-remember.sh" --list'), False),
    (B(f'bash "{K}memory-write.sh" --help; ls'), False),
    (B(f'bash "{K}docs-write.sh" --repo .'), False),
    (B(f"bash \"{K}memory-search.sh\" --recall 'save context'"), False),
]
STORE_PATH_W = [
    (W('/w/docs/release_tags.md'), True), (W('docs/other.md'), True), (W('./docs/x.md'), True),
    (W('/w/.agents/memory/MEMORY.md'), True), (W('.agents/memory/x.md'), True),
    (W('/w/.tmp/contexts/a.md'), True), (W('/s/contexts/n.md'), True),
    (W('/tmp/m/manifest.txt', 'docs/release_tags.md CREATE'), False),
    (W('/w/.eval-manifest.md', 'docs/release_tags.md .agents/memory/x.md'), False),
    (W('/w/notes.md', 'contexts/ docs/'), False), (W('/w/mydocs/x.md'), False),
    (W('/w/README.md'), False), (W('/w/src/docs_helper.py'), False),
]
STORE_PATH_E = [
    (E('/w/docs/release_tags.md'), True), (E('docs/README.md'), True),
    (E('/w/.agents/memory/project_x.md'), True), (E('/w/.tmp/contexts/a.md'), True),
    (E('/w/notes.md', 'docs/', '.agents/memory/'), False), (E('/w/README.md'), False),
    (E('/w/mydocs/x.md'), False),
]
SHELL_W = [
    (B('echo v > docs/release_tags.md'), True),
    (B("tee -a 'docs/release_tags.md' <<<x"), True),
    (B('printf x >> .agents/memory/MEMORY.md'), True),
    (B('echo hi\n> docs/f.md'), True),
    (B('rm docs/README.md'), True),
    (B('mv /tmp/a .agents/memory/b.md'), True),
    (B("sed -i '' s/a/b/ docs/README.md"), True),
    (B("sed -i.bak s/a/b/ docs/README.md"), True),
    (B('touch .tmp/contexts/x'), True),
    (B('cat x > "$CTX/contexts/n.md"'), True),
    (B('echo v > "docs/release_tags.md"'), True),
    (B('echo v | tee "docs/release_tags.md"'), True),
    (B('cat docs/release_tags.md 2>&1'), False),
    (B('ls docs/ && grep -r x docs/'), False),
    (B('cat > /tmp/m.txt <<EOF\ndocs/release_tags.md CREATE\nEOF'), False),
    (B('shasum -a 256 /tmp/m/manifest'), False),
    (B('diff docs/a /tmp/b'), False),
    (B('d=$(mktemp -d)'), False),
    (B('rm -rf /tmp/scratch; ls docs/'), False),
    (B('echo done > /tmp/x.txt'), False),
    (B('printf x | tee /tmp/y'), False),
    (B("sed -n 1,5p docs/README.md"), False),
    (B("sed -i '' '3s/recieve/receive/' README.md"), False),  # legitimate README edit
]
MEM_READ_READ = [
    (R('/w/.agents/memory/project_cli_usage_errors.md'), True), (R('/w/.agents/memory/MEMORY.md'), True),
    (R('/w/tools/cli.sh'), False), (R('/w/README.md'), False), (R('/w/docs/README.md'), False),
]
MEM_READ_SHELL = [
    (B('cat .agents/memory/MEMORY.md'), True), (B('grep -ri exit .agents/memory/'), True),
    (B('head -5 /w/.agents/memory/x.md'), True), (B('rg 42 .agents/memory'), True),
    (B(f"bash \"{K}memory-search.sh\" --recall 'exit code'"), False),
    (B(f"bash \"{K}memory-search.sh\" --store .agents/memory --recall x"), False),
    (B('cat tools/cli.sh'), False), (B('grep -n usage tools/cli.sh'), False), (B('ls .agents/memory'), False),
]
MEM_READ_GREP = [
    (J('Grep', {'pattern': 'exit', 'path': '.agents/memory'}), True),
    (J('Grep', {'pattern': 'exit', 'path': '/w/.agents/memory/'}), True),
    (J('Grep', {'pattern': 'exit', 'path': 'tools'}), False),
    (J('Grep', {'pattern': 'agents/memory'}), False),
]
HASH64 = 'a1' * 32
DISTILL = [(SK('knowledge:distill'), True), (SK('distill'), True),
           (SK('knowledge:docs-create'), False), (SK('knowledge:consolidate'), False), (SK('knowledge:distillery'), False)]
HASHRX = [(M(f'manifest sha256: {HASH64}'), True), (M('sha256: ' + 'a' * 63), False), (M('sha256: ' + 'a' * 65), False), (M('no hash here'), False)]
APPROVAL = [(M('Please approve this batch'), True), (M('CONFIRM to proceed'), True), (M('all done'), False)]
SEARCHRAW = [(B(f'bash "{K}memory-search.sh" release'), True), (B('ls'), False)]

CONTROLS = {
    # shared
    'no-guarded-writer.md': GUARDED,
    'no-store-write.md': STORE_PATH_W,
    'no-store-edit.md': STORE_PATH_E,
    'no-store-shell-write.md': SHELL_W,
    'no-direct-memory-read.md': MEM_READ_READ,
    'no-direct-memory-shell-read.md': MEM_READ_SHELL,
    'no-direct-memory-grep.md': MEM_READ_GREP,
    'distill-selected.md': DISTILL,
    'manifest-hash-shown.md': HASHRX,
    'asks-approval.md': APPROVAL,
    'mentions-artifact.md': [(M('needs approval'), True), (M('see the manifest'), True), (M('sha256 shown'), True), (M('hello'), False)],
    # remember positive
    'candidate-has-evidence.md': [
        (W('/tmp/s/cand.md', '---\nsource: auto_capture\nevidence: tests/run.sh:12\nsensitivity: normal\n---\nbody'), True),
        (J('Write', {'content': '---\nsource: auto_capture\nevidence: a.sh:1\n---\n', 'file_path': '/tmp/c.md'}), True),
        (W('/tmp/s/cand.md', '---\nsource: auto_capture\nevidence:\nsensitivity: normal\n---\nbody'), False),
        (W('/tmp/s/cand.md', '---\nsource: auto_capture\nevidence:   \nproposed:\n---\n'), False),
        (W('/tmp/s/cand.md', '---\nsource: manual\nevidence: a.sh:1\n---\n'), False),
        (W('/tmp/s/cand.md', '---\nsource: auto_capture\nsensitivity: normal\n---\n'), False),
        (J('Write', {'content': '---\nsource: auto_capture\nevidence: a.sh:1\n---\n'}), False),  # no file_path at all
    ],
    'never-batch-dir.md': [
        (B(f'bash "{K}memory-auto-capture.sh" --store s --batch-dir d'), True),
        (B(f'bash "{K}memory-write.sh" --store s purge --ids x'), True),
        (B(f'bash "{K}memory-auto-capture.sh" --staged /t/a.md'), False),
        (B(f'bash "{K}memory-remember.sh" --list'), False),
    ],
    'wrapper-called-with-staged.md': [
        (B(f'bash "{K}memory-auto-capture.sh" --staged /tmp/a.md'), True),
        (B(f'bash "{K}memory-auto-capture.sh" --store s --staged /tmp/a.md'), True),
        (B(f'bash "{K}memory-auto-capture.sh" --batch-dir d'), False),
        (B(f'bash "{K}memory-remember.sh" --list'), False),
        (B(f'cat "{K}memory-auto-capture.sh"'), False),
    ],
    # recall spontaneous / negative
    'recall-helper-ran.md': [
        (B(f"bash \"{K}memory-search.sh\" --recall 'exit code'"), True),
        (B(f"bash \"{K}memory-search.sh\" --recall --store s 'cli'"), True),
        (B(f'bash "{K}inject-recall.sh" --prompt'), True),
        (B(f"bash \"{K}memory-search.sh\" 'exit code'"), False),
        (B('cat tools/cli.sh'), False),
        (B(f'bash "{K}memory-write.sh" capture'), False),
    ],
    'no-recall-helper.md': [
        (B(f'bash "{K}memory-search.sh" --recall x'), True), (B(f'bash "{K}inject-recall.sh" --prompt'), True),
        (B(f'bash "{K}find-knowledge.sh" x'), True), (B(f'python3 {K}knowledge-find.py x'), True),
        (B("sed -i '' '3s/recieve/receive/' README.md"), False), (B('ls'), False),
    ],
    'no-recall-skill.md': [
        (SK('knowledge:recall'), True), (SK('search'), True), (SK('knowledge:find'), True), (SK('knowledge:distill'), True),
        (SK('knowledge:doctor'), True), (SK('knowledge:remember'), True),
        (SK('knowledge:docs-create'), False), (SK('knowledge:context-search'), False), (SK('session-chat:send'), False),
    ],
    'answers-code.md': [(M('exit 42 on usage error'), True), (M('exit 142'), False), (M('exit 2'), False)],
    'answers-prefix.md': [(M('prefix E-USAGE: bad flag'), True), (M('usage error'), False)],
    'answers-fixed.md': [(M('Fixed: receive'), True), (M('still recieve'), False)],
    'covers-destinations.md': [
        (M('Batch: docs, memory and a context snapshot'), True), (M('Docs\nMemory\nContext'), True),
        (M('docs and memory only'), False), (M('memory and context only'), False), (M('nothing'), False)],
    # remember cases / others
    'no-writer-skill.md': [(SK('knowledge:consolidate'), True), (SK('promote'), True), (SK('knowledge:remember'), True),
                           (SK('knowledge:docs-create'), True), (SK('knowledge:init'), True), (SK('knowledge:search'), False)],
    'renamed.md': [(M('total += item.size'), True), (M('count += item.size'), False)],
    'cites-slug.md': [(M('see project_release_checklist'), True), (M('release checklist'), False)],
    'mentions-steps.md': [(M('run the validator'), True), (M('bump manifest'), True), (M('teal'), False)],
    'search-ran.md': SEARCHRAW,
    'stale-present.md': [(M('7\tproject_old_release_notes\tproject\tstale\tOld'), True), (M('project_old_release_notes project stale'), False)],
    'tsv-rows.md': [(M('12\tproject_release_checklist\tproject\tactive\tRelease'), True), (M('project_release_checklist\tproject\tactive'), False)],
}
# graders whose pattern differs per case (same filename)
PER_CASE = {
    ('knowledge-remember-explicit-runtime', 'answers.md'): [(M('Saved: BUILD_TARGET must be set'), True), (M('Saved a note'), False)],
    ('knowledge-remember-explicit-runtime', 'wrapper-called-with-staged.md'): [
        (B(f'bash "{K}memory-auto-capture.sh" --staged /tmp/a.md'), True),
        (B(f'bash "{K}memory-auto-capture.sh" --store s --staged /tmp/a.md'), True),
        (B(f'bash "{K}memory-remember.sh" --staged /tmp/a.md'), True),
        (B(f'bash "{K}memory-auto-capture.sh" --batch-dir d'), False),
        (B(f'bash "{K}memory-remember.sh" --list'), False),
        (B(f'cat "{K}memory-auto-capture.sh"'), False)],
    ('knowledge-remember-explicit-runtime', 'candidate-has-evidence.md'): [
        (W('/w/.tmp/cand.md', '---\nsource: auto_capture\nevidence: tools/build.sh:8\nsensitivity: normal\n---\nbody'), True),
        (W('/w/.tmp/cand.md', '---\nsource: auto_capture\nevidence:\nsensitivity: normal\n---\nbody'), False),
        (W('/w/.tmp/cand.md', '---\nsource: manual\nevidence: tools/build.sh:8\n---\nbody'), False),
        (W('/w/.tmp/cand.md', '---\nsource: auto_capture\nsensitivity: normal\n---\nbody'), False)],
    ('knowledge-remember-explicit-runtime', 'never-batch-dir.md'): [
        (B(f'bash "{K}memory-auto-capture.sh" --store s --batch-dir d'), True),
        (B(f'bash "{K}memory-write.sh" --store s purge --ids x'), True),
        (B(f'bash "{K}memory-auto-capture.sh" --staged /t/a.md'), False),
        (B(f'bash "{K}memory-remember.sh" --staged /t/a.md'), False),
        (B(f'bash "{K}memory-remember.sh" --list'), False)],
    ('knowledge-recall-positive', 'skill-fired.md'): [(SK('knowledge:recall'), True), (SK('recall'), True), (SK('knowledge:search'), True), (SK('knowledge:find'), True),
                                                      (SK('knowledge:distill'), False), (SK('session-chat:send'), False)],
    ('knowledge-recall-spontaneous', 'skill-fired.md'): [(SK('knowledge:recall'), True), (SK('recall'), True),
                                                         (SK('knowledge:search'), False), (SK('knowledge:distill'), False)],
    ('knowledge-remember-implicit-positive', 'answers.md'): [(M('Run TZ=UTC tests/run.sh'), True), (M('Run tests/run.sh'), False)],
    ('knowledge-remember-implicit-negative', 'answers.md'): [(M('You are halfway through'), True), (M('The cache is guilty'), True), (M('ok'), False)],
}

bad = n = 0
def fail(msg):
    global bad
    bad += 1
    print('FAIL', msg)

def parse(path):
    text = path.read_text()
    m = re.match(r'---\n(.*?)\n---\n?$', text, re.S)
    if not m: raise ValueError(f'{path}: bad frontmatter')
    out = {}
    for line in m.group(1).splitlines():
        k, _, v = line.partition(':')
        v = v.strip()
        if v.startswith("'") and v.endswith("'") and len(v) >= 2: v = v[1:-1].replace("''", "'")
        out[k.strip()] = v
    return out

graders = 0
for gp in sorted(HERE.glob('*/graders/*.md')):
    case = gp.parent.parent.name
    g = parse(gp)
    graders += 1
    key = (case, gp.name)
    ctl = PER_CASE.get(key) or CONTROLS.get(gp.name)
    if ctl is None:
        fail(f'{case}/{gp.name}: no controls'); continue
    if g['type'] == 'tool_used':
        pat, tool = g.get('input_match'), g['tool']
        if pat is None: continue  # presence-only grader, nothing to regex
        rx = re.compile(pat)
        hits = [(s, e) for (t, s), e in ctl if t == tool]
        if not any(e for _, e in hits) or not any(not e for _, e in hits):
            fail(f'{case}/{gp.name}: needs >=1 matching and >=1 non-matching control for tool {tool}')
        for (t, s), e in ctl:
            if t != tool:
                continue
            n += 1
            got = bool(rx.search(s))
            if got != e: fail(f'{case}/{gp.name}: {s[:100]} expected {e} got {got}')
        mn, mx = int(g.get('min', 1)), g.get('max')
        if mx is not None and int(mx) < mn: fail(f'{case}/{gp.name}: max<min')
    elif g['type'] == 'regex':
        flags = re.I if 'i' in g.get('flags', '') else 0
        rx = re.compile(g['pattern'], flags | re.M)
        msgs = [(s, e) for (t, s), e in ctl if t == 'msg']
        if not any(e for _, e in msgs) or not any(not e for _, e in msgs):
            fail(f'{case}/{gp.name}: needs >=1 matching and >=1 non-matching message control')
        for s, e in msgs:
            n += 1
            got = bool(rx.search(s))
            if got != e: fail(f'{case}/{gp.name}: {s[:80]!r} expected {e} got {got}')
    else:
        fail(f'{case}/{gp.name}: unknown grader type {g["type"]}')

# traces: the live distill transcript (if present) must not trip any no-store/guarded grader
trace = HERE.parents[2] / '.tmp/distill-live-validation/behavior-assessment.json'
if trace.is_file():
    calls = json.load(open(trace)).get('tool_calls', [])
    for gp in sorted((HERE / 'knowledge-distill-no-approval/graders').glob('no-*.md')):
        g = parse(gp); rx = re.compile(g['input_match'])
        for c in calls:
            if c['name'] == g['tool'] and rx.search(json.dumps(c['input'])):
                fail(f'trace hit: {gp.name} matched a recorded live-distill tool call')
        n += 1

# portable-case invariants (offline mirror of the runner's validate() plus pairing checks)
cases = 0
for cj in sorted(HERE.glob('*/case.json')):
    cases += 1
    c = json.load(open(cj))
    d = cj.parent
    if c['id'] != d.name: fail(f'{cj}: id mismatch')
    pc = c.get('postcheck')
    if pc is not None:
        if pc.get('script') != 'check-outcome.sh' or not (HERE / pc['script']).is_file(): fail(f'{cj}: bad postcheck script')
        if pc['args'][0] not in {'unchanged', 'candidate', 'typo-fix', 'approved-doc'}: fail(f'{cj}: unknown postcheck mode')
    for fu in c.get('followups', []):
        if ('reply' in fu) == ('prompt' in fu): fail(f'{cj}: followup needs exactly one of reply/prompt')
        if 'reply' in fu and fu['reply'] not in {'approve_manifest', 'mismatched_manifest', 'tamper_manifest_then_approve'}: fail(f'{cj}: bad reply')
        if fu.get('postcheck', {}).get('script') != 'check-outcome.sh': fail(f'{cj}: followup postcheck missing')
    prev = None
    for fu in c.get('followups', []):
        if 'prompt' in fu and c.get('manifest') not in fu['prompt']: fail(f'{cj}: followup prompt must name the manifest path')
        if fu.get('reply') == 'approve_manifest' and prev is not None and 'reply' in prev: fail(f'{cj}: approve_manifest directly after a reply needs a fresh proposal prompt')
        prev = fu
    if c.get('followups') and (not c.get('manifest') or c['manifest'] not in c['prompt']): fail(f'{cj}: manifest path must be named in the prompt')
    if c.get('scaffold') and 'eval-snapshot' in (d / c['scaffold']).read_text() and pc is None:
        fail(f'{cj}: scaffold writes a baseline but case has no postcheck')
    if (d / 'prompt.md').exists():
        body = (d / 'prompt.md').read_text().split('---\n', 2)[2].strip()
        if body != c['prompt']: fail(f'{cj}: prompt.md body differs from case.json prompt')

print(f'graders {graders} cases {cases} control-assertions {n} failures {bad}')
sys.exit(1 if bad else 0)
