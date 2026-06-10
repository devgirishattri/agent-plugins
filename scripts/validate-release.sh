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

# Warnings are non-fatal: they are counted and summarized at the end, but the
# script still exits 0 when only warnings were emitted.
WARN_COUNT=0
warn() {
  echo "WARN: $*" >&2
  WARN_COUNT=$((WARN_COUNT + 1))
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
    find codex/plugins \( -name '.mcp.json' -o -name '.app.json' \)
    find codex/plugins -name 'hooks.json'
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

def require_codex_companion(
    manifest: dict,
    codex_dir: pathlib.Path,
    field: str,
    expected_name: str,
    expected_kind: str,
) -> None:
    declared = manifest.get(field)
    companion = codex_dir / expected_name

    if declared is None:
        if companion.exists():
            fail(f"{codex_dir}: {expected_name} exists but manifest omits {field}")
        return

    if not isinstance(declared, str):
        fail(f"{codex_dir}: manifest {field} must be a string path")

    declared_path = codex_dir / declared
    if declared_path != companion:
        fail(f"{codex_dir}: manifest {field} must point to ./{expected_name}")

    if expected_kind == "dir":
        if not declared_path.is_dir():
            fail(f"{codex_dir}: manifest {field} points to missing directory {declared}")
    elif not declared_path.is_file():
        fail(f"{codex_dir}: manifest {field} points to missing file {declared}")

def require_relative_file(codex_dir: pathlib.Path, field: str, value: object) -> None:
    if not isinstance(value, str):
        fail(f"{codex_dir}: interface {field} must be a string path")
    path = codex_dir / value
    try:
        path.relative_to(codex_dir)
    except ValueError:
        fail(f"{codex_dir}: interface {field} must stay inside the plugin directory")
    if not path.is_file():
        fail(f"{codex_dir}: interface {field} points to missing file {value}")

def validate_codex_interface(codex_dir: pathlib.Path, manifest: dict) -> None:
    interface = manifest.get("interface")
    if not isinstance(interface, dict):
        fail(f"{codex_dir}: Codex manifest missing interface object")

    for field in ("displayName", "shortDescription", "longDescription", "developerName", "category"):
        if not isinstance(interface.get(field), str) or not interface[field].strip():
            fail(f"{codex_dir}: interface missing non-empty {field}")

    for field in ("capabilities", "defaultPrompt"):
        value = interface.get(field)
        if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
            fail(f"{codex_dir}: interface {field} must be a non-empty string array")

    for field in ("composerIcon", "logo"):
        if field in interface:
            require_relative_file(codex_dir, field, interface[field])

    screenshots = interface.get("screenshots")
    if screenshots is not None:
        if not isinstance(screenshots, list) or not all(isinstance(item, str) for item in screenshots):
            fail(f"{codex_dir}: interface screenshots must be an array of string paths")
        for screenshot in screenshots:
            require_relative_file(codex_dir, "screenshots", screenshot)

def validate_codex_hooks(codex_dir: pathlib.Path) -> None:
    hooks_path = codex_dir / "hooks.json"
    if not hooks_path.exists():
        return

    hooks_doc = load_json(hooks_path)
    hooks = hooks_doc.get("hooks")
    if not isinstance(hooks, dict) or not hooks:
        fail(f"{hooks_path}: missing non-empty hooks object")

    for event_name, entries in hooks.items():
        if not isinstance(event_name, str) or not event_name:
            fail(f"{hooks_path}: hook event names must be non-empty strings")
        if not isinstance(entries, list) or not entries:
            fail(f"{hooks_path}: event {event_name} must be a non-empty array")
        for entry in entries:
            if not isinstance(entry, dict):
                fail(f"{hooks_path}: event {event_name} entries must be objects")
            if "matcher" in entry and not isinstance(entry["matcher"], str):
                fail(f"{hooks_path}: event {event_name} matcher must be a string")
            commands = entry.get("hooks")
            if not isinstance(commands, list) or not commands:
                fail(f"{hooks_path}: event {event_name} entry missing hooks array")
            for command_hook in commands:
                if not isinstance(command_hook, dict):
                    fail(f"{hooks_path}: command hooks must be objects")
                if command_hook.get("type") != "command":
                    fail(f"{hooks_path}: only command hooks are supported")
                if not isinstance(command_hook.get("command"), str) or not command_hook["command"].strip():
                    fail(f"{hooks_path}: command hook missing command string")
                timeout = command_hook.get("timeout")
                if timeout is not None and not isinstance(timeout, (int, float)):
                    fail(f"{hooks_path}: command hook timeout must be numeric")

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
    if codex_entry.get("version") != codex_manifest.get("version"):
        fail(f"Codex marketplace version does not match manifest for {name}")

    policy = codex_entry.get("policy")
    if not isinstance(policy, dict):
        fail(f"Codex marketplace entry missing policy for {name}")
    if policy.get("installation") not in {"NOT_AVAILABLE", "AVAILABLE", "INSTALLED_BY_DEFAULT"}:
        fail(f"Codex marketplace entry has invalid policy.installation for {name}")
    if policy.get("authentication") not in {"ON_INSTALL", "ON_USE"}:
        fail(f"Codex marketplace entry has invalid policy.authentication for {name}")
    if not codex_entry.get("category"):
        fail(f"Codex marketplace entry missing category for {name}")

    require_codex_companion(codex_manifest, codex_dir, "skills", "skills", "dir")
    require_codex_companion(codex_manifest, codex_dir, "mcpServers", ".mcp.json", "file")
    require_codex_companion(codex_manifest, codex_dir, "apps", ".app.json", "file")
    validate_codex_interface(codex_dir, codex_manifest)
    validate_codex_hooks(codex_dir)

    claude_commands = command_names(claude_dir)
    codex_commands = command_names(codex_dir)
    if claude_commands != codex_commands:
        fail(
            f"command parity mismatch for {name}: "
            f"claude={sorted(claude_commands)} codex={sorted(codex_commands)}"
        )

    codex_skills = skill_names(codex_dir)
    missing_command_skills = codex_commands - codex_skills
    extra_skills = codex_skills - codex_commands
    allowed_overview_skills = {name}
    if missing_command_skills:
        fail(
            f"Codex command skills missing for {name}: "
            f"missing={sorted(missing_command_skills)}"
        )
    if extra_skills - allowed_overview_skills:
        fail(
            f"Unexpected Codex skill without matching command for {name}: "
            f"extra={sorted(extra_skills - allowed_overview_skills)}"
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
        skill_name = None
        for line in frontmatter:
            if ":" not in line:
                fail(f"invalid frontmatter line in {skill_file}: {line}")
            key, value = line.split(":", 1)
            value = value.strip()
            if key == "name":
                skill_name = value.strip("\"'")
            if ": " in value and not value.startswith(("\"", "'")):
                fail(
                    f"frontmatter value with ': ' must be quoted in {skill_file}: {line}"
                )
        if skill_name != skill_file.parent.name:
            fail(f"skill name does not match directory for {skill_file}")

print("OK: marketplace entries, manifests, command parity, Codex skills, and Codex hooks are valid")
PY

# ---------------------------------------------------------------------------
# Mirror drift (Claude plugins/<name>/ vs Codex codex/plugins/<name>/)
# All findings in this section are WARN-level and never change the exit code.
# ---------------------------------------------------------------------------

echo "-- mirror drift checks (warnings only) --"

# Print sorted basenames of files directly inside a directory matching a glob.
# Empty output when the directory does not exist.
list_basenames() {
  local dir="$1" pattern="$2"
  if [ -d "$dir" ]; then
    find "$dir" -maxdepth 1 -type f -name "$pattern" -exec basename {} \; | sort
  fi
}

manifest_version() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version", "unknown"))' "$1"
}

# Warn about basenames present on one side but not the other.
warn_set_diff() {
  local plugin="$1" label="$2" claude_list="$3" codex_list="$4"
  local only_claude only_codex
  only_claude="$(comm -23 <(printf '%s\n' "$claude_list") <(printf '%s\n' "$codex_list") | xargs || true)"
  only_codex="$(comm -13 <(printf '%s\n' "$claude_list") <(printf '%s\n' "$codex_list") | xargs || true)"
  if [ -n "$only_claude" ]; then
    warn "$plugin: $label missing on codex side: $only_claude"
  fi
  if [ -n "$only_codex" ]; then
    warn "$plugin: $label missing on claude side: $only_codex"
  fi
}

for claude_plugin_dir in plugins/*/; do
  plugin_name="$(basename "$claude_plugin_dir")"
  claude_plugin_dir="${claude_plugin_dir%/}"
  codex_plugin_dir="codex/plugins/$plugin_name"
  [ -d "$codex_plugin_dir" ] || continue

  # Command basenames in commands/ on each side.
  claude_commands="$(list_basenames "$claude_plugin_dir/commands" '*.md')"
  codex_commands="$(list_basenames "$codex_plugin_dir/commands" '*.md')"
  warn_set_diff "$plugin_name" "commands" "$claude_commands" "$codex_commands"

  # Hooks presence: Claude keeps hooks/hooks.json, Codex keeps hooks.json.
  claude_has_hooks=false
  codex_has_hooks=false
  if [ -f "$claude_plugin_dir/hooks/hooks.json" ]; then claude_has_hooks=true; fi
  if [ -f "$codex_plugin_dir/hooks.json" ]; then codex_has_hooks=true; fi
  if [ "$claude_has_hooks" != "$codex_has_hooks" ]; then
    warn "$plugin_name: hooks presence mismatch: claude=$claude_has_hooks codex=$codex_has_hooks"
  fi

  # Manifest version drift.
  claude_version="$(manifest_version "$claude_plugin_dir/.claude-plugin/plugin.json")"
  codex_version="$(manifest_version "$codex_plugin_dir/.codex-plugin/plugin.json")"
  if [ "$claude_version" != "$codex_version" ]; then
    newest="$(printf '%s\n%s\n' "$claude_version" "$codex_version" | sort -V | tail -n 1)"
    if [ "$newest" = "$codex_version" ]; then
      direction="codex ahead"
    else
      direction="claude ahead"
    fi
    warn "$plugin_name: claude $claude_version vs codex $codex_version ($direction)"
  fi

  # Script basenames in scripts/ on each side.
  claude_scripts="$(list_basenames "$claude_plugin_dir/scripts" '*')"
  codex_scripts="$(list_basenames "$codex_plugin_dir/scripts" '*')"
  warn_set_diff "$plugin_name" "scripts" "$claude_scripts" "$codex_scripts"
done

if [ "$WARN_COUNT" -gt 0 ]; then
  echo "DONE: validation passed with $WARN_COUNT warning(s); mirror drift is non-fatal"
else
  echo "DONE: validation passed with no warnings"
fi
exit 0
