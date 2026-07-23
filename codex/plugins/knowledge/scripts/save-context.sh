#!/usr/bin/env bash
# save-context.sh — Save a context snapshot for the current project
# Usage: save-context.sh <project-name> <snapshot-file> [--handoff] [--expires <UTC-ISO>]
#
# Phase E (the structured handoff lifecycle): --handoff
# writes/keeps a `kind: handoff` YAML frontmatter block ahead of the body this
# script has always copied unchanged. This is the ONLY surface that mutates
# handoff frontmatter — load/share/diff/list/remove pass the resulting file
# through untouched, since they only ever read or copy bytes.
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PROJECT_NAME="${1:-}"
SNAPSHOT_FILE="${2:-}"

if [ -z "$PROJECT_NAME" ] || [ -z "$SNAPSHOT_FILE" ]; then
  echo "ERROR: Usage: save-context.sh <project-name> <snapshot-file> [--handoff] [--expires <UTC-ISO>]"
  exit 1
fi

# --- Phase E flag parsing (optional; a plain 2-positional call is byte-for-
# byte the pre-Phase-E invocation) ---
if [ $# -ge 2 ]; then
  shift 2
else
  shift $#
fi
HANDOFF=0
EXPIRES_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --handoff)
      HANDOFF=1
      shift
      ;;
    --expires)
      [ $# -ge 2 ] || { echo "ERROR: --expires requires a value" >&2; exit 2; }
      EXPIRES_FLAG="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
if [ -n "$EXPIRES_FLAG" ] && [ "$HANDOFF" -ne 1 ]; then
  echo "ERROR: --expires requires --handoff" >&2
  exit 2
fi
UTC_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
if [ -n "$EXPIRES_FLAG" ] && ! [[ "$EXPIRES_FLAG" =~ $UTC_RE ]]; then
  echo "ERROR: --expires must be a UTC timestamp YYYY-MM-DDTHH:MM:SSZ, got '$EXPIRES_FLAG'" >&2
  exit 2
fi

validate_context_name "$PROJECT_NAME" || exit 1
timezone=$(agent_plugins_timezone) || exit 1

if [ -L "$SNAPSHOT_FILE" ] || [ ! -f "$SNAPSHOT_FILE" ]; then
  echo "ERROR: Snapshot input must be a regular non-symlink file: $SNAPSHOT_FILE"
  exit 1
fi

# _ctx_fm_get <file> <key> -> minimal top-level frontmatter scalar getter.
# Deliberately the same minimal shape as doctor.sh's _kd_fm_get (top-level,
# non-indented "key: value" lines only, between a leading and trailing "---"
# fence) — duplicated here rather than shared because this script and
# doctor.sh are never sourced into one process and lib.sh is not the place
# for context-frontmatter parsing (it stays memory/context mechanics only).
_ctx_fm_get() {
  local file="$1" key="$2" first_line line lineno=0 k v
  IFS= read -r first_line < "$file" 2>/dev/null || return 1
  [ "$first_line" = "---" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [ "$lineno" -eq 1 ] && continue
    [ "$line" = "---" ] && return 1
    case "$line" in
      " "*|$'\t'*) continue ;;
      *:*)
        k="${line%%:*}"
        v="${line#*:}"
        while [ "${v:0:1}" = " " ]; do v="${v:1}"; done
        v="${v%\"}"
        v="${v#\"}"
        if [ "$k" = "$key" ]; then
          printf '%s\n' "$v"
          return 0
        fi
        ;;
    esac
  done < "$file"
  return 1
}

# _ctx_utc_plus14d <UTC-ISO> -> prints <UTC-ISO> + 14 days in the same
# profile. GNU/BSD date fallback, matching lib.sh's context_archive_timestamp_to_epoch.
_ctx_utc_plus14d() {
  local iso="$1" epoch
  epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) || \
    epoch=$(date -u -d "$iso" +%s 2>/dev/null) || return 1
  epoch=$((epoch + 14 * 86400))
  date -j -u -f "%s" "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

SNAPSHOTS_DIR="$(bootstrap_contexts_dir)" || exit 1
DEST="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"
HISTORY_DIR="$SNAPSHOTS_DIR/.history"
MAX_HISTORY=10
LOCK_HELD=0
SCRATCH_FILES=()

cleanup_lock() {
  if [ "$LOCK_HELD" -eq 1 ] || [ -n "${CONTEXT_STORE_LOCK_DIR:-}" ]; then
    release_context_store_lock >/dev/null 2>&1 || true
    LOCK_HELD=0
  fi
  if [ "${#SCRATCH_FILES[@]}" -gt 0 ]; then
    rm -f "${SCRATCH_FILES[@]}" 2>/dev/null || true
  fi
}
handle_signal() {
  cleanup_lock
  trap - EXIT HUP INT TERM
  exit 1
}
trap cleanup_lock EXIT
trap handle_signal HUP INT TERM

acquire_context_store_lock "$SNAPSHOTS_DIR" || exit 1
LOCK_HELD=1

# Harden the whole store UNDER the writer lock. This sweep moved here from the old
# pre-lock get_contexts_dir call: run unlocked, it raced concurrent saves'
# temp/rename and spuriously failed one of several parallel first-time saves.
harden_existing_contexts_dir "$SNAPSHOTS_DIR" >/dev/null || exit 1

# Existing-destination state, read once under the lock: EXISTING_KIND drives
# both the plain-regeneration refusal below and the --handoff transition
# rules further down. Declared unconditionally so `set -u` never trips on an
# unset reference when DEST doesn't exist yet.
EXISTING_KIND=""
EXISTING_CREATED=""
EXISTING_EXPIRES=""

# Inspect the existing destination (read-only, no mutation yet): EXISTING_KIND
# drives both the plain-regeneration refusal below and the --handoff
# transition rules further down. Deliberately separate from, and BEFORE, the
# history-archiving block further down — every validation failure below
# (refusal, malformed --handoff input) must exit before anything is archived
# or overwritten, never after a partial mutation.
if _context_path_exists "$DEST"; then
  ensure_context_regular_file "$DEST" || exit 1

  EXISTING_KIND=$(_ctx_fm_get "$DEST" kind 2>/dev/null) || EXISTING_KIND=""
  if [ "$EXISTING_KIND" = "handoff" ]; then
    EXISTING_CREATED=$(_ctx_fm_get "$DEST" created 2>/dev/null) || EXISTING_CREATED=""
    EXISTING_EXPIRES=$(_ctx_fm_get "$DEST" expires 2>/dev/null) || EXISTING_EXPIRES=""
  fi

  # context-generate without --handoff is byte-identical to the pre-Phase-E
  # behavior on PLAIN snapshots only; regenerating an existing HANDOFF this
  # way would either silently mutate or silently drop its metadata, so it
  # refuses instead with the exact literal stderr line below.
  if [ "$HANDOFF" -eq 0 ] && [ "$EXISTING_KIND" = "handoff" ]; then
    echo "handoff exists: re-run with --handoff" >&2
    exit 2
  fi
fi

SAVE_SOURCE="$SNAPSHOT_FILE"

if [ "$HANDOFF" -eq 1 ]; then
  NOW_UTC=$(km_now_utc)

  if [ "$EXISTING_KIND" = "handoff" ]; then
    # Same-name transition on an existing handoff: keep `created`, advance
    # `updated` to now, keep `expires` unless --expires replaces it.
    if [ -z "$EXISTING_CREATED" ] || [ -z "$EXISTING_EXPIRES" ]; then
      echo "ERROR: existing handoff frontmatter at $DEST is missing created/expires -- refusing to transition a malformed handoff. Run doctor for details." >&2
      exit 1
    fi
    CREATED="$EXISTING_CREATED"
    UPDATED="$NOW_UTC"
    if [ -n "$EXPIRES_FLAG" ]; then
      EXPIRES="$EXPIRES_FLAG"
    else
      EXPIRES="$EXISTING_EXPIRES"
    fi
  else
    # Brand-new handoff, or upgrading an existing PLAIN snapshot: a plain
    # snapshot has no metadata to preserve, so `created` = now either way.
    CREATED="$NOW_UTC"
    UPDATED="$NOW_UTC"
    if [ -n "$EXPIRES_FLAG" ]; then
      EXPIRES="$EXPIRES_FLAG"
    else
      EXPIRES=$(_ctx_utc_plus14d "$NOW_UTC") || {
        echo "ERROR: cannot compute default expires (created + 14d)" >&2
        exit 1
      }
    fi
  fi

  # The staged snapshot file MAY itself begin with a minimal frontmatter
  # fence carrying only a `tickets:` list (the caller's way of citing
  # tracking items on this handoff) -- this is the ONLY field a caller may
  # stage; every other frontmatter field below is computed by this script.
  # No leading fence at all means "no tickets" and the whole file is body,
  # copied through exactly as before.
  TICKETS_BLOCK=""
  BODY_SOURCE="$SNAPSHOT_FILE"
  first_line=""
  IFS= read -r first_line < "$SNAPSHOT_FILE" || first_line=""
  if [ "$first_line" = "---" ]; then
    body_tmp=$(mktemp "${TMPDIR:-/tmp}/km-ctx-body.XXXXXX") || {
      echo "ERROR: cannot create scratch body file" >&2
      exit 1
    }
    SCRATCH_FILES+=("$body_tmp")
    tickets_tmp=$(mktemp "${TMPDIR:-/tmp}/km-ctx-tickets.XXXXXX") || {
      echo "ERROR: cannot create scratch tickets file" >&2
      exit 1
    }
    SCRATCH_FILES+=("$tickets_tmp")

    state=fence
    lineno=0
    saw_tickets_key=0
    malformed=0
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno + 1))
      [ "$lineno" -eq 1 ] && continue
      case "$state" in
        fence)
          if [ "$line" = "---" ]; then
            state=body
            continue
          fi
          if [ "$lineno" -eq 2 ]; then
            if [ "$line" = "tickets:" ]; then
              saw_tickets_key=1
            else
              malformed=1
            fi
            continue
          fi
          case "$line" in
            "  -"*) printf '%s\n' "$line" >> "$tickets_tmp" ;;
            *) malformed=1 ;;
          esac
          ;;
        body)
          printf '%s\n' "$line" >> "$body_tmp"
          ;;
      esac
    done < "$SNAPSHOT_FILE"

    if [ "$state" != "body" ]; then
      echo "ERROR: staged snapshot frontmatter fence never closed: $SNAPSHOT_FILE" >&2
      exit 2
    fi
    if [ "$saw_tickets_key" -ne 1 ] || [ "$malformed" -eq 1 ]; then
      echo "ERROR: staged snapshot frontmatter must contain only a 'tickets:' list (one '  - ' item per line): $SNAPSHOT_FILE" >&2
      exit 2
    fi
    if [ -s "$tickets_tmp" ]; then
      TICKETS_BLOCK=$(cat "$tickets_tmp")
    fi
    BODY_SOURCE="$body_tmp"
  fi

  combined=$(mktemp "${TMPDIR:-/tmp}/km-ctx-combined.XXXXXX") || {
    echo "ERROR: cannot create scratch combined file" >&2
    exit 1
  }
  SCRATCH_FILES+=("$combined")
  {
    echo "---"
    echo "handoff_version: 1"
    echo "kind: handoff"
    echo "created: $CREATED"
    echo "updated: $UPDATED"
    echo "expires: $EXPIRES"
    if [ -n "$TICKETS_BLOCK" ]; then
      echo "tickets:"
      printf '%s\n' "$TICKETS_BLOCK"
    fi
    echo "---"
    cat "$BODY_SOURCE"
  } > "$combined"
  SAVE_SOURCE="$combined"
fi

# Version history: archive the previous snapshot before overwriting it.
# Brand-new names create no history entry. Deliberately placed AFTER every
# validation above (refusal check, --handoff computation, tickets-fragment
# parsing) so a rejected call never leaves a spurious archived version behind.
if _context_path_exists "$DEST"; then
  if [ -L "$HISTORY_DIR" ]; then
    _context_store_error "history directory cannot be a symbolic link: $HISTORY_DIR"
    exit 1
  fi
  if [ ! -d "$HISTORY_DIR" ]; then
    mkdir -m 700 "$HISTORY_DIR" || {
      _context_store_error "cannot create history directory: $HISTORY_DIR"
      exit 1
    }
  fi
  _context_harden_directory "$HISTORY_DIR" || exit 1
  ts=$(TZ="$timezone" date +%Y%m%d-%H%M%S%z)
  while _context_path_exists "$HISTORY_DIR/${PROJECT_NAME}.${ts}.md"; do
    sleep 1
    ts=$(TZ="$timezone" date +%Y%m%d-%H%M%S%z)
  done
  archive_mode=$(context_safe_file_mode "$DEST") || exit 1
  atomic_copy_context_file "$DEST" "$HISTORY_DIR/${PROJECT_NAME}.${ts}.md" "$archive_mode" || exit 1
  echo "Archived previous version to $HISTORY_DIR/${PROJECT_NAME}.${ts}.md"
  # Cap history at MAX_HISTORY versions per name (delete oldest beyond that)
  excess=$(context_history_versions "$PROJECT_NAME" "$HISTORY_DIR" | tail -n +$((MAX_HISTORY + 1)) || true)
  if [ -n "$excess" ]; then
    echo "$excess" | while IFS= read -r old; do
      ensure_context_regular_file "$old" || exit 1
      rm -f "$old" || exit 1
    done || exit 1
  fi
fi

atomic_copy_context_file "$SAVE_SOURCE" "$DEST" 600 || exit 1
ensure_context_regular_file "$DEST" || exit 1
release_context_store_lock || exit 1
LOCK_HELD=0
trap - EXIT HUP INT TERM
echo "Saved context snapshot for '$PROJECT_NAME' at $DEST"
