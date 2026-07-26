#!/usr/bin/env bash
# workspace-install.sh — install this plugin's machine-wide `workspace`
# dispatcher onto the user's PATH.
#
# WHY THIS EXISTS: the dispatcher (templates/workspace-dispatcher.sh) has to
# live on PATH, outside any plugin cache, because it is what FINDS the plugin.
# That makes it a copy, and a copy goes stale silently. This verb is the
# refresh: it is idempotent, it always copies from the plugin it is running
# from (never from a source checkout), and `upgrade.sh` calls it after every
# plugin update so the copy cannot drift from the release.
#
# Deliberately NOT done here:
#   * no config discovery — a fresh machine has no project yet, so this verb
#     must work with no .agent-workspace/ anywhere;
#   * no shell-rc editing — the alias line is PRINTED for the user to add,
#     never written. Editing someone's rc file behind their back is exactly
#     the kind of surprise a bootstrap step must not spring.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd)"
SOURCE="$PLUGIN_ROOT/templates/workspace-dispatcher.sh"

DEFAULT_TARGET="$HOME/.local/bin/workspace"
TARGET="$DEFAULT_TARGET"
DRY_RUN=0

usage() {
  echo "Usage: workspace.sh install [--target PATH] [--dry-run]" >&2
  echo "  --target PATH   install location (default: $DEFAULT_TARGET)" >&2
  echo "  --dry-run       report what would happen; write nothing" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      shift
      [ "$#" -gt 0 ] || { echo "ERROR: --target needs a path." >&2; exit 2; }
      TARGET="$1"
      ;;
    --target=*)
      TARGET="${1#--target=}"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'." >&2
      usage
      exit 2
      ;;
  esac
  shift
done

[ -n "$TARGET" ] || { echo "ERROR: --target must not be empty." >&2; exit 2; }

if [ ! -f "$SOURCE" ]; then
  echo "ERROR: dispatcher template missing from this install: $SOURCE" >&2
  echo "       This plugin copy is incomplete — reinstall session-workspace." >&2
  exit 1
fi

echo "session-workspace install"
echo "  source: $SOURCE"
echo "  target: $TARGET"

TARGET_DIR="$(dirname "$TARGET")"

# Idempotence: an identical target is a no-op, so `upgrade.sh` can call this
# unconditionally on every run without churn or spurious backups.
if [ -f "$TARGET" ] && cmp -s "$SOURCE" "$TARGET"; then
  echo "  [ok] already current — nothing to do"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -e "$TARGET" ]; then
      echo "  [dry-run] would back up the existing file to $TARGET.bak and overwrite it"
    else
      echo "  [dry-run] would create $TARGET"
    fi
  else
    if [ ! -d "$TARGET_DIR" ]; then
      mkdir -p "$TARGET_DIR" || { echo "ERROR: cannot create $TARGET_DIR" >&2; exit 1; }
      echo "  [new] created $TARGET_DIR"
    fi
    # Back up whatever is there now — including a hand-written dispatcher this
    # verb is replacing. Never overwrite an existing file without a copy.
    if [ -e "$TARGET" ]; then
      cp "$TARGET" "$TARGET.bak" || { echo "ERROR: cannot back up $TARGET" >&2; exit 1; }
      echo "  [backup] previous version saved to $TARGET.bak"
    fi
    cp "$SOURCE" "$TARGET" || { echo "ERROR: cannot write $TARGET" >&2; exit 1; }
    chmod 0755 "$TARGET" || { echo "ERROR: cannot chmod $TARGET" >&2; exit 1; }
    echo "  [installed] $TARGET"
  fi
fi

# Verify the installed copy actually answers, rather than assuming the cp
# worked: this is the same "invoke it the way a user does" check that a
# missing install would otherwise fail silently.
if [ "$DRY_RUN" -eq 0 ] && [ -x "$TARGET" ]; then
  if bash "$TARGET" --contract >/dev/null 2>&1; then
    echo "  [ok] installed dispatcher resolves an engine and answers --contract"
  else
    echo "  [warn] installed, but it could not resolve a session-workspace engine yet." >&2
    echo "         That is expected only if no provider has the plugin installed." >&2
  fi
fi

# PATH membership — report, never modify.
case ":${PATH}:" in
  *":$TARGET_DIR:"*)
    echo "  [ok] $TARGET_DIR is on your PATH"
    ;;
  *)
    echo "  [warn] $TARGET_DIR is NOT on your PATH — add it, e.g.:" >&2
    echo "           export PATH=\"$TARGET_DIR:\$PATH\"" >&2
    ;;
esac

echo
echo "Run it as: $(basename "$TARGET") <doctor|plan|start|status|restart|reconcile|stop>"
echo "Optional shorthand — add to your shell rc yourself (this never edits it):"
echo "    alias ws=$(basename "$TARGET")"
exit 0
