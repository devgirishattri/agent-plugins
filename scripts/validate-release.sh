#!/usr/bin/env bash
# Validate provider plugin metadata before publishing.

set -euo pipefail

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

cd "$ROOT"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "OK: $*"
}

[ -f ".claude-plugin/marketplace.json" ] || fail "missing .claude-plugin/marketplace.json"
[ -f ".agents/plugins/marketplace.json" ] || fail "missing .agents/plugins/marketplace.json"
[ ! -e "docs/TODO.md" ] || fail "docs/TODO.md should not be published; use GitHub Issues instead"

while IFS= read -r json_file; do
  python3 -m json.tool "$json_file" >/dev/null
done < <(
  {
    printf '%s\n' ".claude-plugin/marketplace.json"
    printf '%s\n' ".agents/plugins/marketplace.json"
    find plugins codex/plugins -path '*/.claude-plugin/plugin.json' -o -path '*/.codex-plugin/plugin.json'
  } | sort
)
info "JSON manifests are valid"

while IFS= read -r shell_file; do
  bash -n "$shell_file"
done < <(find plugins codex/plugins scripts -type f -name '*.sh' | sort)
info "shell scripts parse"

python3 <<'PY'
import json
import pathlib
import sys

root = pathlib.Path.cwd()

def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)

def load_json(path: pathlib.Path):
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        fail(f"{path}: {exc}")

def command_names(path: pathlib.Path) -> set[str]:
    commands_dir = path / "commands"
    if not commands_dir.is_dir():
        fail(f"missing commands directory: {commands_dir}")
    return {item.stem for item in commands_dir.glob("*.md")}

def skill_names(path: pathlib.Path) -> set[str]:
    skills_dir = path / "skills"
    if not skills_dir.is_dir():
        return set()
    return {item.parent.name for item in skills_dir.glob("*/SKILL.md")}

claude_marketplace = load_json(root / ".claude-plugin" / "marketplace.json")
codex_marketplace = load_json(root / ".agents" / "plugins" / "marketplace.json")

claude_plugins = {entry["name"]: entry for entry in claude_marketplace.get("plugins", [])}
codex_plugins = {entry["name"]: entry for entry in codex_marketplace.get("plugins", [])}

if set(claude_plugins) != set(codex_plugins):
    fail(
        "provider marketplace plugin sets differ: "
        f"claude={sorted(claude_plugins)} codex={sorted(codex_plugins)}"
    )

for name in sorted(claude_plugins):
    claude_entry = claude_plugins[name]
    codex_entry = codex_plugins[name]

    claude_dir = root / claude_entry["source"]
    codex_dir = root / codex_entry["source"]["path"]

    if not claude_dir.is_dir():
        fail(f"Claude plugin directory missing for {name}: {claude_dir}")
    if not codex_dir.is_dir():
        fail(f"Codex plugin directory missing for {name}: {codex_dir}")

    claude_manifest = load_json(claude_dir / ".claude-plugin" / "plugin.json")
    codex_manifest = load_json(codex_dir / ".codex-plugin" / "plugin.json")

    if claude_manifest.get("name") != name:
        fail(f"Claude manifest name mismatch for {name}")
    if codex_manifest.get("name") != name:
        fail(f"Codex manifest name mismatch for {name}")
    if claude_entry.get("version") != claude_manifest.get("version"):
        fail(f"Claude marketplace version does not match manifest for {name}")

    claude_commands = command_names(claude_dir)
    codex_commands = command_names(codex_dir)
    if claude_commands != codex_commands:
        fail(
            f"command parity mismatch for {name}: "
            f"claude={sorted(claude_commands)} codex={sorted(codex_commands)}"
        )

    codex_skills = skill_names(codex_dir)
    if codex_skills and codex_skills != codex_commands:
        fail(
            f"Codex skill/command mismatch for {name}: "
            f"skills={sorted(codex_skills)} commands={sorted(codex_commands)}"
        )

    for skill_file in sorted((codex_dir / "skills").glob("*/SKILL.md")):
        text = skill_file.read_text()
        lines = text.splitlines()
        if len(lines) < 4 or lines[0] != "---":
            fail(f"missing YAML frontmatter: {skill_file}")
        try:
            end = lines.index("---", 1)
        except ValueError:
            fail(f"unterminated YAML frontmatter: {skill_file}")
        frontmatter = lines[1:end]
        if not any(line.startswith("name:") for line in frontmatter):
            fail(f"missing skill name in frontmatter: {skill_file}")
        if not any(line.startswith("description:") for line in frontmatter):
            fail(f"missing skill description in frontmatter: {skill_file}")
        for line in frontmatter:
            if ":" not in line:
                fail(f"invalid frontmatter line in {skill_file}: {line}")
            _, value = line.split(":", 1)
            value = value.strip()
            if ": " in value and not value.startswith(("\"", "'")):
                fail(
                    f"frontmatter value with ': ' must be quoted in {skill_file}: {line}"
                )

print("OK: marketplace entries, manifests, command parity, and Codex skills are valid")
PY
