#!/usr/bin/env python3
"""Check/package reviewed shell fragments inline in standalone plugin libraries.

Default is read-only. --write requires an explicit provider so independent
provider owners can package their own trees without touching the other tree.
Only named, reviewed functions are eligible; this is not a shell formatter.
"""
import argparse
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
# Only explicitly reviewed provider-neutral files. Identity hooks, Chronos,
# session metadata, and context dependency resolvers are intentional shims.
# Older context-script drift remains an inventory, not a normalization target.
SHARED_FILES=("memory-search.sh","inject-recall.sh","test-batch-search.sh")
FALLBACK_FUNCTIONS=("kc_get_my_name","kc_resolve_pane","kc_send_text","kc_send_message")


def function(text,name):
    matches=list(re.finditer(r"^"+re.escape(name)+r"\(\) \{\n(.*?)^\}\n",text,re.M|re.S))
    if len(matches)!=1:
        raise ValueError(f"expected exactly one {name} function, found {len(matches)}")
    return matches[0]


def package(root,provider=None,write=False):
    canonical=(root/"shared/shell/validate-label.sh").read_text()
    body=function(canonical,"validate_label").group(1)
    problems=[]
    for current,prefix in (("claude",Path("plugins")),("codex",Path("codex/plugins"))):
        if provider and provider!=current: continue
        for plugin,name in (("session-chat","validate_label"),("knowledge","kc_validate_label")):
            path=root/prefix/plugin/"scripts/lib.sh"
            text=path.read_text(); match=function(text,name)
            if match.group(1)==body: continue
            if write:
                path.write_text(text[:match.start(1)]+body+text[match.end(1):])
            else:
                problems.append(f"{path.relative_to(root)}: {name} differs from canonical fragment")
    return problems


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider",choices=("claude","codex"))
    parser.add_argument("--write",action="store_true")
    args=parser.parse_args()
    if args.write and not args.provider: parser.error("--write requires --provider")
    problems=package(ROOT,args.provider,args.write)
    if not args.write:
        for name in SHARED_FILES:
            path=Path("plugins/knowledge/scripts")/name
            if (ROOT/path).read_bytes() != (ROOT/"codex"/path).read_bytes():
                problems.append(f"{path}: reviewed provider-neutral file differs from Codex mirror")
        claude=(ROOT/"plugins/knowledge/scripts/lib.sh").read_text()
        codex=(ROOT/"codex/plugins/knowledge/scripts/lib.sh").read_text()
        for name in FALLBACK_FUNCTIONS:
            if function(claude,name).group(0) != function(codex,name).group(0):
                problems.append(f"knowledge fallback {name}: provider body differs")
    if problems: raise SystemExit("\n".join(problems))
    print("PASS: reviewed shared helpers are packaged identically")

if __name__=="__main__": main()
