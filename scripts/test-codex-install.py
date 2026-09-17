#!/usr/bin/env python3
"""Native installation contract in a disposable CODEX_HOME; no login or model calls."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def check_skills(plugin):
    files = list(plugin.glob("skills/*/SKILL.md"))
    generated = list(plugin.glob(".codex-plugin/migrated-command-skills/*/SKILL.md"))
    assert not generated, f"duplicate generated command skills: {generated}"
    for skill in files:
        text = skill.read_text()
        for helper in re.findall(r"(?:<PLUGIN_ROOT>|\$\{?PLUGIN_ROOT\}?)/scripts/([\w.-]+)", text):
            assert (plugin / "scripts" / helper).is_file(), (skill, helper)
        for ref in re.findall(r"\]\(([^)]+\.md)\)", text):
            if not ref.startswith(("https://", "http://")) and "<" not in ref:
                assert (skill.parent / ref).is_file(), (skill, ref)
    return {p.parent.name for p in files}


with tempfile.TemporaryDirectory(prefix="codex-install-contract-") as temp:
    base = Path(temp)
    market = base / "market"
    home = base / "home"
    home.mkdir()
    shutil.copytree(ROOT / ".agents/plugins", market / ".agents/plugins")
    shutil.copytree(ROOT / "codex", market / "codex")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CODEX_", "SESSION_", "KNOWLEDGE_", "TMUX"))}
    env["CODEX_HOME"] = str(home)
    def cli(*args):
        result = subprocess.run(["codex", *args], env=env, text=True,
                                capture_output=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return json.loads(result.stdout)
    cli("plugin", "marketplace", "add", str(market), "--json")
    for source in sorted((ROOT / "codex/plugins").iterdir()):
        if not source.is_dir():
            continue
        installed = cli("plugin", "add", source.name + "@girishattri-plugins", "--json")
        actual = check_skills(Path(installed["installedPath"]))
        expected = {p.parent.name for p in source.glob("skills/*/SKILL.md")}
        assert expected == actual, (source.name, expected - actual, actual - expected)
        print(f"PASS {source.name}: {len(actual)} public skills, no generated duplicates, helpers resolve")
