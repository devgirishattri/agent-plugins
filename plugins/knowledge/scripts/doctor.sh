#!/usr/bin/env bash
# doctor.sh — read-only, cross-store health checks for the knowledge plugin
# (the doctor contract). One command that aggregates
# findings across every store this plugin knows about: docs (taxonomy,
# decision-record naming, stale pointers, link/marker validation), the
# memory module (Phases B1-B3: lint, index reconciliation, backlinks,
# capture inbox, decay/review queue, store hardening, lock/journal/staged
# diagnostics), the context store (mtime-based staleness, matching the
# absorbed load-context.sh + SESSION_CONTEXT_STALE_DAYS behavior, LAYERED
# with the Phase E `expires`-metadata tier for `kind: handoff` snapshots —
# both tiers fire independently for the same file — plus Phase E's handoff
# ticket-citation checks), the AGENTS.md recall-instruction bridge, the
# provider capability matrix (Claude autoMemoryDirectory + Codex native-
# memories disk-baseline).
#
# STRICTLY READ-ONLY: every check here reads, stats, or invokes another
# read-only helper (memory-lint.sh, memory-index.sh, memory-backlinks.sh
# report mode, memory-remember.sh --list, check-todos.sh, validate-links.sh,
# check-freshness.sh) — it never writes, chmods, locks, mutates, or invokes
# memory-write.sh (not even `unlock`, which itself removes a dead lock: this
# script only DIAGNOSES the same lock/claim/journal/staged files that
# `unlock` would act on, reporting the exact recovery command instead of
# running it). Acceptance requires byte-identical trees before/after a run.
#
# Usage: doctor.sh [--store <path>]
#   --store <path>   explicit memory-store target, same precedence as every
#                     other memory-store command (explicit >
#                     KNOWLEDGE_MEMORY_HOME > canonical discovery under
#                     <repo-root>/.agents/memory/). Governs ONLY the memory-
#                     module + lock-diagnostics sections; docs/context/
#                     AGENTS.md/capability-matrix sections
#                     always target the repository root, matching "docs
#                     commands target the repo root" in the zero-config
#                     contract, and never take --store.
#   anything else     usage error, exit 2. This is the whole argv grammar —
#                     no other flags exist.
#
# Output: one finding per stdout line, "<LEVEL>\t<section>\t<message>" with
#   LEVEL in INFO|WARN|ERROR. A section that cannot run (missing target,
#   unreadable) reports a finding for that fact and the remaining sections
#   still run — this script only aborts before running ANY section when the
#   hard-failure condition below is hit.
#
# Exit codes: 0 clean (no WARN/ERROR finding — INFO findings may still be
#   present); 1 findings present (at least one WARN or ERROR — doctor is a
#   REPORTER, not a mutating helper, so its own aggregate exit collapses to
#   "clean vs. findings present" rather than reusing the memory-kernel's
#   2/3/4/5/6 per-defect-class exit map, which stays meaningful only for the
#   individual tools doctor wraps); 2 usage error; 3 hard failure — no
#   section could run at all (the CWD is not inside a git repository, so
#   neither the memory resolver, the docs/context repo-root convention, nor
#   the AGENTS.md check have anywhere to look).
#
# Supported platforms: macOS, Linux. The provider capability-matrix's
# JSON-backed checks (Claude autoMemoryDirectory) use python3 when available (same
# established dependency as memory-search.sh) and degrade to a single INFO
# note — never a hard failure — when it is not; every other section is pure
# bash/coreutils. The Codex native-memories config.toml scan is pure bash
# (no python3 dependency) and always runs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

LINT="$HERE/memory-lint.sh"
INDEXTOOL="$HERE/memory-index.sh"
BACKLINKS="$HERE/memory-backlinks.sh"
REMEMBER="$HERE/memory-remember.sh"
WRITER="$HERE/memory-write.sh"
CHECK_TODOS="$HERE/check-todos.sh"
VALIDATE_LINKS="$HERE/validate-links.sh"
CHECK_FRESHNESS="$HERE/check-freshness.sh"
RECALL_SNIPPET="$(cd "$HERE/.." && pwd)/assets/recall-snippet.md"

# ---------------------------------------------------------------------------
# argv — exactly `[--store <path>]`, anything else is exit 2.
# ---------------------------------------------------------------------------
store_arg=""
have_store=0
while [ $# -gt 0 ]; do
  case "$1" in
    --store)
      [ $# -ge 2 ] || { echo "ERROR: --store requires a value" >&2; exit 2; }
      [ "$have_store" -eq 0 ] || { echo "ERROR: --store may be given only once" >&2; exit 2; }
      store_arg="$2"
      have_store=1
      shift 2
      ;;
    *)
      echo "ERROR: Usage: doctor.sh [--store <path>]" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# reporting infrastructure
# ---------------------------------------------------------------------------
HAS_FINDING=0
emit() {
  local level="$1" section="$2" msg="$3"
  printf '%s\t%s\t%s\n' "$level" "$section" "$msg"
  case "$level" in
    WARN|ERROR) HAS_FINDING=1 ;;
  esac
  return 0
}

# _kd_oneline <text> -> collapses embedded newlines/tabs/CRs to single spaces
# so a multi-line captured tool message can never break the one-finding-per-
# stdout-line contract.
_kd_oneline() {
  printf '%s' "$1" | tr '\n\t\r' '   ' | sed 's/  */ /g'
}

_kd_mtime_epoch() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

_kd_now_epoch() {
  date -u +%s
}

_kd_have_python3() {
  command -v python3 >/dev/null 2>&1
}

# _kd_fm_get <file> <key> -> prints the top-level (non-indented) scalar
# frontmatter value (surrounding quotes stripped) for <key> and returns 0;
# returns 1 if the file has no opening/closing "---" fence or the key is
# absent. Deliberately minimal (top-level scalars only — review_after and
# status are always top-level scalars per the v1 schema): memory-lint.sh has
# the fuller two-tier parser, but it has no dispatch guard (sourcing it runs
# its own store lint immediately), so it is not safely reusable here.
_kd_fm_get() {
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

# _kd_fm_list <file> <key> -> prints each item of a top-level YAML list key
# (one per stdout line, the "  - " prefix and any wrapping quotes stripped)
# between the frontmatter fence -- companion to the scalar-only _kd_fm_get,
# needed for the handoff `tickets:` list (Phase E). Same minimal-grammar
# tolerance as _kd_fm_get and save-context.sh's own writer-side reader:
# top-level key line must be the literal "<key>:" (no inline value), and
# every immediately-following "  - " line is one item; anything else ends
# the list. Returns 0 (possibly printing nothing) if the key was found;
# returns 1 if there is no frontmatter fence or the key is absent.
_kd_fm_list() {
  local file="$1" key="$2" first_line line lineno=0 in_list=0 item found=0
  IFS= read -r first_line < "$file" 2>/dev/null || return 1
  [ "$first_line" = "---" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [ "$lineno" -eq 1 ] && continue
    if [ "$line" = "---" ]; then
      [ "$found" -eq 1 ] && return 0
      return 1
    fi
    case "$line" in
      "  -"*)
        if [ "$in_list" -eq 1 ]; then
          item="${line#  -}"
          while [ "${item:0:1}" = " " ]; do item="${item:1}"; done
          item="${item%\"}"
          item="${item#\"}"
          printf '%s\n' "$item"
        fi
        continue
        ;;
      "${key}:")
        in_list=1
        found=1
        continue
        ;;
      *)
        in_list=0
        continue
        ;;
    esac
  done < "$file"
  [ "$found" -eq 1 ] && return 0
  return 1
}

# _kd_iso_to_epoch <UTC-ISO YYYY-MM-DDTHH:MM:SSZ> -> epoch seconds.
# GNU/BSD date fallback, the same pattern save-context.sh's own
# _ctx_utc_plus14d and lib.sh's context_archive_timestamp_to_epoch use.
_kd_iso_to_epoch() {
  local iso="$1"
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || date -u -d "$iso" +%s 2>/dev/null
}

# _kd_canon_path <raw> <base> -> best-effort canonicalization of a possibly
# ~-relative or repo-relative path against <base>, falling back to the
# uncanonicalized expansion when the path does not exist on disk.
_kd_canon_path() {
  local raw="$1" base="$2" expanded resolved
  case "$raw" in
    \~) expanded="$HOME" ;;
    \~/*) expanded="$HOME/${raw#\~/}" ;;
    /*) expanded="$raw" ;;
    *) expanded="$base/$raw" ;;
  esac
  resolved=$(cd "$expanded" 2>/dev/null && pwd -P) || resolved="$expanded"
  printf '%s\n' "$resolved"
}

# ---------------------------------------------------------------------------
# JSON helpers (python3-backed; used only by the Claude capability-matrix
# row). Every other section is pure bash.
# ---------------------------------------------------------------------------

# _kd_json_get <file> <dotted.key> -> prints the scalar value on stdout.
# Exit: 0 found; 2 key absent (or non-scalar path partially missing);
# 3 file missing/unreadable/invalid JSON.
_kd_json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(3)
cur = data
for part in key.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(2)
if cur is None:
    sys.exit(2)
if isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
PY
}

# _kd_json_enabled_plugins <file> -> one "plugin@marketplace" key per line
# for every enabledPlugins entry whose value is literally true. Exit 3 if
# the file is missing/unreadable/invalid JSON (caller treats that as "no
# entries from this file", not a hard error — this is a best-effort scan).
_kd_json_enabled_plugins() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(3)
ep = data.get("enabledPlugins")
if not isinstance(ep, dict):
    sys.exit(0)
for k, v in ep.items():
    if v is True:
        print(k)
PY
}

# ---------------------------------------------------------------------------
# Section: docs — taxonomy placement, decision-record naming, and the
# absorbed validators (check-todos.sh, validate-links.sh, check-freshness.sh)
# reused verbatim (invoke, don't reimplement).
# ---------------------------------------------------------------------------
section_docs() {
  local docs_dir="$repo_root/docs"
  if [ -L "$docs_dir" ] || [ ! -d "$docs_dir" ]; then
    emit INFO docs-taxonomy "no docs/ directory found at $docs_dir — docs checks skipped"
    return 0
  fi

  # --- decision-record naming: docs/decisions/<snake_case>.md, with dates in
  # metadata instead of the filename.
  local dec_dir="$docs_dir/decisions"
  local dec_re='^[a-z0-9]+(_[a-z0-9]+)*\.md$'
  local dec_date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  if [ -d "$dec_dir" ] && [ ! -L "$dec_dir" ]; then
    local f base decided
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      base=$(basename "$f")
      if [[ ! "$base" =~ $dec_re ]]; then
        emit WARN docs-taxonomy "bad decision naming: docs/decisions/$base (expected snake_case.md; put dates in decided: metadata, not the filename)"
      fi
      decided=$(_kd_fm_get "$f" decided) || decided=""
      if [ -z "$decided" ]; then
        emit WARN docs-taxonomy "decision metadata missing: docs/decisions/$base (expected frontmatter decided: YYYY-MM-DD)"
      elif [[ ! "$decided" =~ $dec_date_re ]]; then
        emit WARN docs-taxonomy "decision metadata invalid: docs/decisions/$base (decided is not YYYY-MM-DD: '$decided')"
      fi
    done < <(find "$dec_dir" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
  fi

  # --- taxonomy placement: a legacy DEC-* file living anywhere in docs/ OTHER
  # than docs/decisions/ is still recognized as a misplaced decision record.
  local f rel base
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$repo_root"/}"
    case "$rel" in
      docs/decisions/*) continue ;;
    esac
    base=$(basename "$f")
    case "$base" in
      DEC-*.md)
        emit WARN docs-taxonomy "misplaced legacy decision record: $rel (decision records belong under docs/decisions/<snake_case>.md with decided metadata)"
        ;;
    esac
  done < <(find "$docs_dir" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

  # --- embedded TODO:/FIXME:/HACK: markers (absorbed check-todos.sh; by
  # design it skips TODO.md/ISSUES.md, the tracker artifacts) ---
  local todos_out
  todos_out=$(bash "$CHECK_TODOS" "$docs_dir" 2>&1)
  local block_file="" block_lines="" line
  while IFS= read -r line; do
    case "$line" in
      "FOUND in "*":")
        if [ -n "$block_file" ]; then
          emit WARN docs-todos "embedded TODO:/FIXME:/HACK: marker in $block_file —$block_lines"
        fi
        block_file="${line#FOUND in }"
        block_file="${block_file%:}"
        block_lines=""
        ;;
      "  "*)
        block_lines="$block_lines ${line#  }"
        ;;
      "")
        if [ -n "$block_file" ]; then
          emit WARN docs-todos "embedded TODO:/FIXME:/HACK: marker in $block_file —$block_lines"
        fi
        block_file=""
        block_lines=""
        ;;
      *) : ;;
    esac
  done <<< "$todos_out"
  if [ -n "$block_file" ]; then
    emit WARN docs-todos "embedded TODO:/FIXME:/HACK: marker in $block_file —$block_lines"
  fi

  # --- broken cross-references (absorbed validate-links.sh) ---
  local links_out
  links_out=$(bash "$VALIDATE_LINKS" "$docs_dir" 2>&1)
  while IFS= read -r line; do
    case "$line" in
      "BROKEN: "*)
        emit WARN docs-links "${line#BROKEN: }"
        ;;
    esac
  done <<< "$links_out"

  # --- staleness vs. referenced code (absorbed check-freshness.sh, 30d
  # threshold — matching the established docs-review/docs-create convention)
  local fresh_out stale_doc=""
  fresh_out=$(bash "$CHECK_FRESHNESS" "$docs_dir" 30 2>&1)
  while IFS= read -r line; do
    case "$line" in
      "STALE: "*)
        stale_doc="${line#STALE: }"
        ;;
      "  -> "*)
        if [ -n "$stale_doc" ]; then
          emit WARN docs-freshness "$stale_doc -- ${line#  -> }"
          stale_doc=""
        fi
        ;;
      *) : ;;
    esac
  done <<< "$fresh_out"
}

# ---------------------------------------------------------------------------
# Section: memory module (Phases B1-B3) — resolve the store, then compose
# every read-only tool's own report rather than reimplementing any of them,
# plus the two pieces new in this phase: decay/review-queue reporting and
# store-hardening checks.
# ---------------------------------------------------------------------------
section_memory() {
  local store_err_file="$WORKDIR/store_resolve.err"
  STORE=$(km_resolve_store "$store_arg" 2>"$store_err_file")
  local rc=$?
  local err
  err=$(cat "$store_err_file" 2>/dev/null)

  if [ "$rc" -ne 0 ]; then
    STORE=""
    case "$err" in
      *"no memory store found"*)
        emit INFO memory-resolve "memory store not initialized: $(_kd_oneline "$err")"
        ;;
      *"ambiguous memory store"*)
        emit WARN memory-resolve "memory store resolution is ambiguous: $(_kd_oneline "$err")"
        ;;
      *)
        if [ "$rc" -eq 4 ]; then
          emit ERROR memory-resolve "memory store integrity failure: $(_kd_oneline "$err")"
        else
          emit WARN memory-resolve "memory store could not be resolved: $(_kd_oneline "$err")"
        fi
        ;;
    esac
    return 0
  fi

  emit INFO memory-resolve "memory store resolved: $STORE"

  # --- lint (memory-lint.sh): ERROR -> doctor ERROR, ADVISORY -> doctor
  # INFO (non-blocking migration guidance), any other level -> WARN.
  local lint_out level file msg
  lint_out=$(bash "$LINT" --store "$STORE" 2>&1)
  while IFS=$'\t' read -r level file msg; do
    [ -n "$level" ] || continue
    case "$level" in
      ERROR) emit ERROR memory-lint "$file: $msg" ;;
      ADVISORY) emit INFO memory-lint "$file: $msg" ;;
      *) emit WARN memory-lint "$file: $msg" ;;
    esac
  done <<< "$lint_out"

  # --- index reconciliation (memory-index.sh): every DRIFT is a genuine,
  # actionable inconsistency worth surfacing even though the tool's own exit
  # code treats DRIFT as informational-not-error.
  local idx_out tag kind detail
  idx_out=$(bash "$INDEXTOOL" --store "$STORE" 2>&1)
  while IFS=$'\t' read -r tag kind detail; do
    [ -n "$tag" ] || continue
    [ "$tag" = "DRIFT" ] || continue
    emit WARN memory-index "$kind: $detail"
  done <<< "$idx_out"

  # --- backlinks report mode (memory-backlinks.sh report; always its own
  # exit 0 unless a store-integrity condition aborts it first) ---
  local bl_err bl_rc bl_line
  bl_err=$(bash "$BACKLINKS" --store "$STORE" report 2>&1 1>/dev/null)
  bl_rc=$?
  if [ "$bl_rc" -ne 0 ]; then
    emit ERROR memory-backlinks "backlinks report failed (rc=$bl_rc): $(_kd_oneline "$bl_err")"
  else
    while IFS= read -r bl_line; do
      [ -n "$bl_line" ] || continue
      emit WARN memory-backlinks "$bl_line"
    done <<< "$bl_err"
  fi

  # --- capture inbox (memory-remember.sh --list, read-only per its own
  # docstring) ---
  local rem_out rem_rc id created age verdict sens pending=0 expired=0
  rem_out=$(bash "$REMEMBER" --store "$STORE" --list 2>&1)
  rem_rc=$?
  if [ "$rem_rc" -eq 0 ]; then
    # shellcheck disable=SC2034  # sens: column captured for TSV shape, unused
    while IFS=$'\t' read -r id created age verdict sens; do
      [ -n "$id" ] || continue
      pending=$((pending + 1))
      if [ "$verdict" = "expired" ]; then
        expired=$((expired + 1))
        emit WARN memory-inbox "expired capture candidate $id (created $created, age ${age}d) -- review with memory-remember.sh --store $STORE --list --expired-only, then memory-write.sh purge --expired"
      fi
    done <<< "$rem_out"
    if [ "$pending" -gt 0 ]; then
      emit INFO memory-inbox "$pending capture candidate(s) pending ($expired expired)"
    fi
  else
    emit ERROR memory-inbox "capture inbox listing failed (rc=$rem_rc): $(_kd_oneline "$rem_out")"
  fi

  # --- decay / review queue (v1 rule: review_after past-or-today OR status
  # stale/superseded; order review_after asc with unset last, then slug asc)
  local queue_file="$WORKDIR/review_queue.tsv"
  : > "$queue_file"
  local today
  today=$(date -u +%Y-%m-%d)
  local f stem review_after status due reason sortkey
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    stem="${f%.md}"
    review_after=$(_kd_fm_get "$STORE/$f" review_after) || review_after=""
    status=$(_kd_fm_get "$STORE/$f" status) || status=""
    [ -n "$status" ] || status="active"
    due=0
    reason=""
    if [ -n "$review_after" ] && [[ "$review_after" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      if [[ ! "$review_after" > "$today" ]]; then
        due=1
        reason="review_after $review_after has passed"
      fi
    fi
    case "$status" in
      stale|superseded)
        due=1
        if [ -n "$reason" ]; then
          reason="$reason; status: $status"
        else
          reason="status: $status"
        fi
        ;;
    esac
    if [ "$due" -eq 1 ]; then
      if [ -n "$review_after" ] && [[ "$review_after" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        sortkey="0:$review_after:$stem"
      else
        sortkey="1:9999-99-99:$stem"
      fi
      printf '%s\t%s\t%s\n' "$sortkey" "$stem" "$reason" >> "$queue_file"
    fi
  done < <(km_authoritative_files "$STORE")

  if [ -s "$queue_file" ]; then
    local stem2 reason2
    while IFS=$'\t' read -r sortkey stem2 reason2; do
      [ -n "$stem2" ] || continue
      emit INFO memory-review-queue "$stem2.md due for review ($reason2)"
    done < <(LC_ALL=C sort "$queue_file")
  fi

  # --- store hardening: gitignore coverage + permissions (read-only stats
  # only — never chmod, matching "reject symlinked/foreign-owner/traversal
  # targets" and "keep owner-only permissions" as VALIDATION here, not
  # enforcement; km_resolve_store already fails closed on symlink/foreign-
  # owner/traversal, so this only adds gitignore + mode checks) ---
  if km_verify_gitignored "$STORE" 2>/dev/null; then
    :
  else
    emit ERROR memory-hardening "memory store is not covered by .gitignore: $STORE -- compliance-sensitive content could be committed"
  fi

  local dir_mode
  dir_mode=$(km_path_mode "$STORE" 2>/dev/null) || dir_mode=""
  if [ -n "$dir_mode" ] && [ "$dir_mode" != "700" ]; then
    emit WARN memory-hardening "memory store directory mode is $dir_mode, expected 700: $STORE (run: chmod 700 $STORE)"
  fi
  local mem_mode
  mem_mode=$(km_path_mode "$STORE/MEMORY.md" 2>/dev/null) || mem_mode=""
  if [ -n "$mem_mode" ] && [ "$mem_mode" != "600" ]; then
    emit WARN memory-hardening "MEMORY.md mode is $mem_mode, expected 600: $STORE/MEMORY.md (run: chmod 600 $STORE/MEMORY.md)"
  fi
  local fmode
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    fmode=$(km_path_mode "$STORE/$f" 2>/dev/null) || continue
    if [ "$fmode" != "600" ]; then
      emit WARN memory-hardening "$f mode is $fmode, expected 600: $STORE/$f (run: chmod 600 $STORE/$f)"
    fi
  done < <(km_authoritative_files "$STORE")

  if [ -d "$STORE/.inbox" ] && [ ! -L "$STORE/.inbox" ]; then
    local inbox_mode
    inbox_mode=$(km_path_mode "$STORE/.inbox" 2>/dev/null) || inbox_mode=""
    if [ -n "$inbox_mode" ] && [ "$inbox_mode" != "700" ]; then
      emit WARN memory-hardening ".inbox mode is $inbox_mode, expected 700: $STORE/.inbox (run: chmod 700 $STORE/.inbox)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Section: orphaned locks/journals/staged/claims — composes the same checks
# memory-write.sh's `unlock` subcommand reports (KM_SELF-relative unlock
# command, dead-pid vs. alive-but-long-held distinction, orphaned claim
# files), entirely read-only: this NEVER invokes `unlock` itself, since
# unlock removes a dead lock (a write). Only runs when a memory store
# resolved.
# ---------------------------------------------------------------------------
section_locks() {
  [ -n "$STORE" ] || return 0

  local unlock_cmd="bash $WRITER unlock --store $STORE --confirm $STORE"
  local lock="$STORE/.lock"
  local holder_claim=""

  if [ -e "$lock" ] || [ -L "$lock" ]; then
    if [ -L "$lock" ] || [ ! -f "$lock" ]; then
      emit ERROR memory-lock "$lock exists but is not a safe regular file"
    else
      local lock_id="" f fid
      lock_id=$(km_path_identity "$lock" 2>/dev/null) || lock_id=""
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        fid=$(km_path_identity "$f" 2>/dev/null) || continue
        if [ -n "$lock_id" ] && [ "$fid" = "$lock_id" ]; then
          holder_claim="$f"
        fi
      done < <(find "$STORE" -mindepth 1 -maxdepth 1 -name '.lock.claim.*' 2>/dev/null)

      if [ -z "$holder_claim" ]; then
        emit ERROR memory-lock "cannot identify the holder claim for $lock (store-integrity)"
      else
        local holder_pid
        holder_pid=$(grep -m1 '^pid: ' "$holder_claim" 2>/dev/null | sed 's/^pid: //')
        if [ -z "$holder_pid" ]; then
          emit ERROR memory-lock "lock claim has no readable pid: $holder_claim"
        elif ! km_pid_alive "$holder_pid"; then
          emit WARN memory-lock "stale lock: holder pid $holder_pid is dead ($lock) -- run: $unlock_cmd"
        else
          local lock_epoch now age_s
          lock_epoch=$(_kd_mtime_epoch "$lock") || lock_epoch=""
          now=$(_kd_now_epoch)
          if [ -n "$lock_epoch" ]; then
            age_s=$((now - lock_epoch))
            if [ "$age_s" -gt 600 ]; then
              emit WARN memory-lock "long-held lock: holder pid $holder_pid is alive but has held $lock for ${age_s}s (over 10min) -- if the holder is confirmed dead, run: $unlock_cmd"
            fi
          fi
        fi
      fi

      # Any OTHER claim file besides the identified holder is orphaned --
      # normally a contention loser cleans up its own claim, so a survivor
      # here means that cleanup did not happen.
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$f" = "$holder_claim" ] && continue
        emit WARN memory-lock "orphaned claim file: $f"
      done < <(find "$STORE" -mindepth 1 -maxdepth 1 -name '.lock.claim.*' 2>/dev/null)
    fi
  else
    # No lock: every claim file present is orphaned, mirroring
    # memory-write.sh's own _km_report_orphaned_claims when no lock exists.
    local f
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      emit WARN memory-lock "orphaned claim file: $f (no active lock)"
    done < <(find "$STORE" -mindepth 1 -maxdepth 1 -name '.lock.claim.*' 2>/dev/null)
  fi

  if [ -d "$STORE/.journal" ]; then
    emit WARN memory-lock "unrecovered journal at $STORE/.journal -- a prior write transaction was interrupted; it auto-recovers on the next memory-write.sh invocation"
  fi

  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    emit WARN memory-lock "orphaned journal temp: $f (dead generation, auto-cleared on the next memory-write.sh invocation)"
  done < <(find "$STORE" -mindepth 1 -maxdepth 1 -name '.journal.tmp.*' 2>/dev/null)

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    emit WARN memory-lock "orphaned staged directory: $f (dead generation, auto-cleared on the next memory-write.sh invocation)"
  done < <(find "$STORE" -mindepth 1 -maxdepth 1 -name '.staged.*' 2>/dev/null)
}

# _kd_classify_citation <citation> -> sets KD_CITE_KIND
# (ext|local-verified|local-stale|malformed) and KD_CITE_DETAIL. Grammar per
# the tracking-items boundary: `ext:<ID>` with ID
# matching [A-Z][A-Z0-9]+-[0-9]+; `local:<tracker-path>:<prefix>` split on
# the SECOND colon (path may not contain ':'), prefix non-empty, path not
# absolute and containing no '..', naming exactly TODO.md/ISSUES.md at the
# repo root or under docs/, verified via `grep -F -q` for the prefix inside
# that file. An independent doctor-side implementation of the identical
# rules test-promotion.sh's own test-local classify_citation() validates
# (that file is never sourced here). Uses the global $repo_root.
_kd_classify_citation() {
  local citation="$1"
  KD_CITE_KIND="malformed"
  KD_CITE_DETAIL=""
  case "$citation" in
    ext:*)
      local id="${citation#ext:}"
      if [[ "$id" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; then
        KD_CITE_KIND="ext"
        KD_CITE_DETAIL="$id"
      else
        KD_CITE_DETAIL="malformed ext: ticket id in '$citation'"
      fi
      ;;
    local:*)
      local rest path prefix full
      rest="${citation#local:}"
      path="${rest%%:*}"
      prefix="${rest#*:}"
      if [ "$path" = "$rest" ]; then
        KD_CITE_DETAIL="local: citation missing the second colon: '$citation'"
        return 0
      fi
      if [ -z "$prefix" ]; then
        KD_CITE_DETAIL="local: citation has an empty prefix: '$citation'"
        return 0
      fi
      case "$path" in
        /*)
          KD_CITE_DETAIL="local: tracker path must not be absolute: '$citation'"
          return 0
          ;;
      esac
      case "$path" in
        *..*)
          KD_CITE_DETAIL="local: tracker path must not contain '..': '$citation'"
          return 0
          ;;
      esac
      case "$path" in
        TODO.md|ISSUES.md|docs/TODO.md|docs/ISSUES.md) : ;;
        *)
          KD_CITE_DETAIL="local: tracker path is not a recognized tracker file (TODO.md/ISSUES.md at the repo root or under docs/): '$path'"
          return 0
          ;;
      esac
      full="$repo_root/$path"
      if [ -L "$full" ] || [ ! -f "$full" ]; then
        KD_CITE_KIND="local-stale"
        KD_CITE_DETAIL="$path (tracker file not found)"
        return 0
      fi
      if grep -F -q -- "$prefix" "$full"; then
        KD_CITE_KIND="local-verified"
        KD_CITE_DETAIL="$path: $prefix"
      else
        KD_CITE_KIND="local-stale"
        KD_CITE_DETAIL="$path (prefix not found: $prefix)"
      fi
      ;;
    *)
      KD_CITE_DETAIL="unrecognized citation grammar: '$citation'"
      ;;
  esac
}

# _kd_check_handoff <file> <name> -- Phase E additions layered on top of the
# mtime tier in section_context: required-field validation, expiry, and
# ticket-citation checks for a snapshot whose `kind: handoff` frontmatter
# key the caller already confirmed. Every malformed/missing field is its
# own ordinary WARN and never aborts the remaining checks for this file or
# any other (same "report, don't abort" rule as every other section).
_kd_check_handoff() {
  local file="$1" name="$2"
  local utc_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  local handoff_version created updated expires expires_ok=1

  handoff_version=$(_kd_fm_get "$file" handoff_version) || handoff_version=""
  if [ "$handoff_version" != "1" ]; then
    emit WARN context-handoff "malformed handoff frontmatter: '$name' (handoff_version missing or not '1': '${handoff_version:-<absent>}')"
  fi

  created=$(_kd_fm_get "$file" created) || created=""
  if [ -z "$created" ]; then
    emit WARN context-handoff "malformed handoff frontmatter: '$name' (missing required field: created)"
  elif [[ ! "$created" =~ $utc_re ]]; then
    emit WARN context-handoff "malformed handoff frontmatter: '$name' (created is not a UTC timestamp YYYY-MM-DDTHH:MM:SSZ: '$created')"
  fi

  updated=$(_kd_fm_get "$file" updated) || updated=""
  if [ -z "$updated" ]; then
    emit WARN context-handoff "malformed handoff frontmatter: '$name' (missing required field: updated)"
  elif [[ ! "$updated" =~ $utc_re ]]; then
    emit WARN context-handoff "malformed handoff frontmatter: '$name' (updated is not a UTC timestamp YYYY-MM-DDTHH:MM:SSZ: '$updated')"
  fi

  expires=$(_kd_fm_get "$file" expires) || expires=""
  if [ -z "$expires" ]; then
    emit WARN context-handoff "malformed handoff frontmatter: '$name' (missing required field: expires)"
    expires_ok=0
  elif [[ ! "$expires" =~ $utc_re ]]; then
    emit WARN context-handoff "malformed handoff frontmatter: '$name' (expires is not a UTC timestamp YYYY-MM-DDTHH:MM:SSZ: '$expires')"
    expires_ok=0
  fi

  if [ "$expires_ok" -eq 1 ]; then
    local expires_epoch now_epoch expired_days
    expires_epoch=$(_kd_iso_to_epoch "$expires") || expires_epoch=""
    if [ -n "$expires_epoch" ]; then
      now_epoch=$(_kd_now_epoch)
      if [ "$expires_epoch" -lt "$now_epoch" ]; then
        expired_days=$(( (now_epoch - expires_epoch) / 86400 ))
        emit WARN context-handoff "expired handoff '$name' (expired ${expired_days}d ago, expires $expires) -- eligible for confirmed cleanup via /knowledge:promote; never auto-deleted"
      fi
    fi
  fi

  # Ticket-citation checks are independent of the required-field validation
  # above -- a handoff can have a broken `expires` and a perfectly fine
  # `tickets:` list, or vice versa; both run regardless of the other.
  local citation
  while IFS= read -r citation; do
    [ -n "$citation" ] || continue
    _kd_classify_citation "$citation"
    case "$KD_CITE_KIND" in
      ext)
        emit INFO context-handoff "handoff '$name' cites external ticket $KD_CITE_DETAIL -- unverifiable, never fetched"
        ;;
      local-verified)
        emit INFO context-handoff "handoff '$name' cites local tracker $KD_CITE_DETAIL -- verified"
        ;;
      local-stale)
        emit WARN context-handoff "handoff '$name' cites a stale local: tracker reference: $KD_CITE_DETAIL"
        ;;
      malformed)
        emit WARN context-handoff "handoff '$name' cites a malformed ticket reference: $KD_CITE_DETAIL"
        ;;
    esac
  done < <(_kd_fm_list "$file" tickets)
}

# ---------------------------------------------------------------------------
# Section: context store health — the mtime tier (matching the absorbed
# load-context.sh + SESSION_CONTEXT_STALE_DAYS behavior) LAYERED with the
# Phase E expires-metadata tier + handoff ticket-citation checks for any
# snapshot whose frontmatter declares `kind: handoff` (a file without
# frontmatter, or without that key, is a plain snapshot and gets the mtime
# check only, per the spec's own discriminator). Both tiers run
# independently per file -- a handoff can be mtime-stale, expired, both, or
# neither. Read-only throughout: unlike get_contexts_dir(), this never
# hardens/chmods the tree, and _kd_check_handoff only ever reads.
# ---------------------------------------------------------------------------
section_context() {
  local ctx_dir="${SESSION_CONTEXT_HOME:-$repo_root/.tmp/contexts}"
  if [ ! -e "$ctx_dir" ]; then
    emit INFO context "no context store found at $ctx_dir"
    return 0
  fi
  if [ -L "$ctx_dir" ] || [ ! -d "$ctx_dir" ]; then
    emit WARN context "context store path is unsafe (symlink or not a directory): $ctx_dir"
    return 0
  fi

  local stale_days="${SESSION_CONTEXT_STALE_DAYS:-7}"
  local now
  now=$(_kd_now_epoch)
  local f base mtime age_days kind
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    [ -L "$f" ] && continue
    base=$(basename "$f" .md)

    mtime=$(_kd_mtime_epoch "$f") || continue
    age_days=$(( (now - mtime) / 86400 ))
    if [ "$age_days" -ge "$stale_days" ]; then
      emit WARN context "stale context snapshot '$base' (${age_days}d old, threshold ${stale_days}d) -- consider /knowledge:context-generate $base"
    fi

    kind=$(_kd_fm_get "$f" kind) || kind=""
    if [ "$kind" = "handoff" ]; then
      _kd_check_handoff "$f" "$base"
    fi
  done < <(find "$ctx_dir" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null | LC_ALL=C sort)

  if [ -d "$ctx_dir/.knowledge-context.lock" ]; then
    emit INFO context "an active context-store writer lock is present at $ctx_dir/.knowledge-context.lock (informational -- normal during a concurrent /context-* write; the context-store lock lifecycle is unchanged in this phase)"
  fi
}

# ---------------------------------------------------------------------------
# Section: AGENTS.md recall-instruction bridge (report + exact snippet,
# NEVER edit AGENTS.md).
# ---------------------------------------------------------------------------
AGENTS_MD_MARKER_OK=0
_kd_print_snippet() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf 'INFO\tagents-md\tsnippet> %s\n' "$line"
  done < "$RECALL_SNIPPET"
}

section_agents_md() {
  AGENTS_MD_MARKER_OK=0
  local agents_file="$repo_root/AGENTS.md"
  local start_marker='<!-- knowledge:recall:start -->'
  local end_marker='<!-- knowledge:recall:end -->'

  if [ ! -f "$agents_file" ] || [ -L "$agents_file" ]; then
    emit WARN agents-md "AGENTS.md not found at $repo_root -- add the recall bridge snippet (paste exactly):"
    _kd_print_snippet
    return 0
  fi

  local start_count end_count
  start_count=$(grep -Fxc -- "$start_marker" "$agents_file" 2>/dev/null || true)
  end_count=$(grep -Fxc -- "$end_marker" "$agents_file" 2>/dev/null || true)
  [ -n "$start_count" ] || start_count=0
  [ -n "$end_count" ] || end_count=0

  if [ "$start_count" -ne 1 ] || [ "$end_count" -ne 1 ]; then
    emit WARN agents-md "recall-snippet marker pair missing or duplicated in AGENTS.md (start=$start_count, end=$end_count) -- paste exactly:"
    _kd_print_snippet
    return 0
  fi

  local start_line end_line
  start_line=$(grep -Fxn -- "$start_marker" "$agents_file" | head -1 | cut -d: -f1)
  end_line=$(grep -Fxn -- "$end_marker" "$agents_file" | head -1 | cut -d: -f1)
  if [ -z "$start_line" ] || [ -z "$end_line" ] || [ "$end_line" -lt "$start_line" ]; then
    emit WARN agents-md "recall-snippet markers are malformed (end before start) in AGENTS.md -- paste exactly:"
    _kd_print_snippet
    return 0
  fi

  local extracted="$WORKDIR/agents_snippet_actual.txt"
  local expected="$WORKDIR/agents_snippet_expected.txt"
  sed -n "${start_line},${end_line}p" "$agents_file" | tr -d '\r' > "$extracted"
  tr -d '\r' < "$RECALL_SNIPPET" > "$expected"

  if cmp -s "$extracted" "$expected"; then
    AGENTS_MD_MARKER_OK=1
    emit INFO agents-md "recall-snippet present and byte-equal to the canonical asset"
  else
    emit WARN agents-md "recall-snippet body diverges from the canonical asset in AGENTS.md -- paste exactly:"
    _kd_print_snippet
  fi
}

# ---------------------------------------------------------------------------
# Section: provider capability matrix (Claude autoMemoryDirectory + Codex
# native-memories disk-baseline) + shared-store recall / two-recall-layers.
# ---------------------------------------------------------------------------
CODEX_MEMORIES_ACTIVE=0

_kd_capability_claude() {
  local found=0 first_canon="" first_label="" first_out=""
  local pair f label out rc canon
  for pair in \
    "$HOME/.claude/settings.json|user" \
    "$repo_root/.claude/settings.json|project" \
    "$repo_root/.claude/settings.local.json|project-local"
  do
    f="${pair%%|*}"
    label="${pair#*|}"
    [ -f "$f" ] && [ ! -L "$f" ] || continue

    out=$(_kd_json_get "$f" autoMemoryDirectory); rc=$?
    case "$rc" in
      0)
        found=1
        emit INFO capability-claude "autoMemoryDirectory ($label settings, $f): $out -- caveat: managed-policy/--settings sources are unobservable from disk and may override observable settings"
        case "$out" in
          /*|\~|\~/*) ;;
          *)
            emit WARN capability-claude "autoMemoryDirectory ($label settings, $f: $out) is not an absolute path or ~/ path -- Claude Code requires one of those forms"
            ;;
        esac
        canon=$(_kd_canon_path "$out" "$repo_root")
        if [ -n "$first_canon" ] && [ "$canon" != "$first_canon" ]; then
          emit WARN capability-claude "observable autoMemoryDirectory values differ ($first_label settings: $first_out -> $first_canon; $label settings: $out -> $canon) -- Claude settings precedence determines the active value"
        fi
        if [ -z "$first_canon" ]; then
          first_canon="$canon"
          first_label="$label"
          first_out="$out"
        fi
        if [ -n "$STORE" ] && [ "$canon" != "$STORE" ]; then
          emit WARN capability-claude "autoMemoryDirectory ($label settings: $out -> $canon) diverges from the resolved memory store ($STORE) -- Claude's auto-recall will read a different location than the /knowledge commands"
        fi
        ;;
      2)
        ;;
      *)
        emit INFO capability-claude "autoMemoryDirectory: $label settings file $f is present but unreadable/invalid JSON"
        ;;
    esac
  done

  if [ "$found" -eq 0 ]; then
    emit INFO capability-claude "autoMemoryDirectory not set in observable settings (user: $HOME/.claude/settings.json; project: $repo_root/.claude/settings.json; project-local: $repo_root/.claude/settings.local.json) -- caveat: managed-policy/--settings sources are unobservable from disk and may still set it"
  fi
}

# _kd_codex_layer <path> -> sets KD_LAYER_STATUS (absent|unreadable|ok),
# KD_LAYER_FLAG, and KD_LAYER_OBSERVATION (both meaningful only when ok).
# Grammar scanned (spec: "[features] memories / memories.*"; ground truth
# from the live Codex owner, codex-cli 0.145.0 / openai/codex main:
# `features.memories` is the ONE activation flag and defaults to false;
# `MemoriesConfig`'s `generate_memories`/`use_memories` etc. under
# `[memories]` are TUNING keys that default true but never activate the
# feature by themselves):
#   - KD_LAYER_FLAG = the value of the ACTIVATION key `features.memories`,
#     read either as `memories = <value>` inside a `[features]` table, or
#     the equivalent top-level dotted form `features.memories = <value>`
#     (both are the same TOML key). This is the ONLY signal this script
#     ever treats as activating the row.
#   - KD_LAYER_OBSERVATION = a non-empty, purely informational note when a
#     `[memories]` table header and/or `memories.*` tuning keys (dotted
#     top-level, or as sub-keys of a `[memories]` table) are present WITHOUT
#     `features.memories` also being set in this same file -- these must
#     never be treated as activation on their own (that was a bug: a bare
#     `[memories]` table or tuning-keys-only file used to report the
#     sentinel "table-present" and got treated as active, a false positive;
#     fixed to be observation-only).
_kd_codex_layer() {
  local path="$1"
  KD_LAYER_STATUS="absent"
  KD_LAYER_FLAG=""
  KD_LAYER_OBSERVATION=""
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    KD_LAYER_STATUS="unreadable"
    return 0
  fi
  local owner
  owner=$(km_path_uid "$path" 2>/dev/null) || { KD_LAYER_STATUS="unreadable"; return 0; }
  if [ "$owner" != "$(id -u)" ]; then
    KD_LAYER_STATUS="unreadable"
    return 0
  fi
  if [ ! -r "$path" ]; then
    KD_LAYER_STATUS="unreadable"
    return 0
  fi
  KD_LAYER_STATUS="ok"

  local section="" line trimmed key val memories_table_seen=0 tuning_keys=""
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      ""|\#*) continue ;;
      \[*\])
        section="${trimmed#[}"
        section="${section%%]*}"
        [ "$section" = "memories" ] && memories_table_seen=1
        continue
        ;;
    esac
    case "$trimmed" in
      *=*)
        key="${trimmed%%=*}"
        while [ "${key: -1}" = " " ] || [ "${key: -1}" = "$(printf '\t')" ]; do key="${key%?}"; done
        val="${trimmed#*=}"
        val="${val%%#*}"
        while [ "${val:0:1}" = " " ] || [ "${val:0:1}" = "$(printf '\t')" ]; do val="${val:1}"; done
        while [ "${val: -1}" = " " ] || [ "${val: -1}" = "$(printf '\t')" ]; do val="${val%?}"; done
        val="${val#\"}"
        val="${val%\"}"

        if { [ "$section" = "features" ] && [ "$key" = "memories" ]; } \
          || { [ -z "$section" ] && [ "$key" = "features.memories" ]; }; then
          KD_LAYER_FLAG="$val"
        elif [ "$section" = "memories" ]; then
          tuning_keys="${tuning_keys:+$tuning_keys, }$key=$val"
        elif [ -z "$section" ]; then
          case "$key" in
            memories.*) tuning_keys="${tuning_keys:+$tuning_keys, }${key#memories.}=$val" ;;
          esac
        fi
        ;;
    esac
  done < "$path"

  if [ -z "$KD_LAYER_FLAG" ]; then
    if [ -n "$tuning_keys" ]; then
      KD_LAYER_OBSERVATION="memories table/tuning keys present but inactive ($tuning_keys)"
    elif [ "$memories_table_seen" -eq 1 ]; then
      KD_LAYER_OBSERVATION="memories table present but inactive (no tuning keys read, no activation flag)"
    fi
  fi
}

_kd_capability_codex() {
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local user_toml="$codex_home/config.toml"
  local codex_repo_root=""
  if [ -n "$STORE" ]; then
    codex_repo_root=$(km_git_ancestor "$STORE" 2>/dev/null) || codex_repo_root=""
  fi
  [ -n "$codex_repo_root" ] || codex_repo_root="$repo_root"
  local project_toml="$codex_repo_root/.codex/config.toml"

  emit INFO capability-codex "system layer: unknown (no documented on-disk path for this layer is known to this plugin)"

  # resolved_value/resolved_source track ONLY the activation flag
  # (features.memories), last-defining-layer-wins, exactly as before.
  # weak_value/weak_source track the informational table/tuning-keys-only
  # observation (also last-layer-wins among itself) and are used ONLY as a
  # fallback display when NO layer ever defines the activation flag -- a
  # layer that only has weak/tuning content never overrides a real
  # true/false set at an earlier layer (an absent key does not erase a
  # previously-set one).
  local resolved_value="" resolved_source="default"
  local weak_value="" weak_source=""

  _kd_codex_layer "$user_toml"
  case "$KD_LAYER_STATUS" in
    ok)
      if [ -n "$KD_LAYER_FLAG" ]; then
        emit INFO capability-codex "user layer ($user_toml): features.memories = $KD_LAYER_FLAG"
        resolved_value="$KD_LAYER_FLAG"
        resolved_source="user"
      elif [ -n "$KD_LAYER_OBSERVATION" ]; then
        emit INFO capability-codex "user layer ($user_toml): features.memories key absent ($KD_LAYER_OBSERVATION)"
        weak_value="table-present-inactive"
        weak_source="user"
      else
        emit INFO capability-codex "user layer ($user_toml): features.memories key absent"
      fi
      ;;
    absent) emit INFO capability-codex "user layer ($user_toml): file absent" ;;
    unreadable) emit INFO capability-codex "user layer ($user_toml): unreadable (symlink, foreign owner, or permission-denied) -- source unknown for this layer" ;;
  esac

  _kd_codex_layer "$project_toml"
  case "$KD_LAYER_STATUS" in
    ok)
      if [ -n "$KD_LAYER_FLAG" ]; then
        emit INFO capability-codex "project layer ($project_toml): features.memories = $KD_LAYER_FLAG"
        resolved_value="$KD_LAYER_FLAG"
        resolved_source="project"
      elif [ -n "$KD_LAYER_OBSERVATION" ]; then
        emit INFO capability-codex "project layer ($project_toml): features.memories key absent ($KD_LAYER_OBSERVATION)"
        weak_value="table-present-inactive"
        weak_source="project"
      else
        emit INFO capability-codex "project layer ($project_toml): features.memories key absent"
      fi
      ;;
    absent) emit INFO capability-codex "project layer ($project_toml): file absent" ;;
    unreadable) emit INFO capability-codex "project layer ($project_toml): unreadable (symlink, foreign owner, or permission-denied) -- source unknown for this layer" ;;
  esac

  if [ "$resolved_source" = "default" ]; then
    if [ -n "$weak_source" ]; then
      resolved_value="$weak_value"
      resolved_source="$weak_source"
    else
      resolved_value="disabled"
    fi
  fi
  emit INFO capability-codex "resolved native-memories: $resolved_value (source: $resolved_source) -- DISK-BASELINE only, never 'effective'/'global'; profile/CLI/per-chat layers are not observable from disk"

  # ACTIVE iff features.memories is explicitly true at some readable layer
  # (ground truth: default is false; MemoriesConfig tuning keys never
  # activate anything by themselves, so "table-present-inactive" -- or any
  # other non-"true" resolved value -- must never flip this on).
  CODEX_MEMORIES_ACTIVE=0
  if [ "$resolved_value" = "true" ]; then
    CODEX_MEMORIES_ACTIVE=1
  fi
}

section_capability_matrix() {
  emit INFO capability-matrix "matrix rows are informational (disk-derived state, not live provider introspection)"

  if _kd_have_python3; then
    _kd_capability_claude
  else
    emit INFO capability-claude "python3 is not available on this host -- the JSON-backed autoMemoryDirectory checks are skipped"
  fi

  _kd_capability_codex

  local shared_recall=0
  if [ "$AGENTS_MD_MARKER_OK" -eq 1 ] && [ -n "$STORE" ]; then
    shared_recall=1
    emit INFO capability-recall "shared-store recall is configured (recall-snippet verified and the memory resolver resolves a store)"
  fi
  if [ "$shared_recall" -eq 1 ] && [ "$CODEX_MEMORIES_ACTIVE" -eq 1 ]; then
    emit INFO capability-recall "two recall layers are active: this plugin's shared store AND Codex native memories -- see AGENTS.md's precedence note (required policy > shared project knowledge > personal native memories)"
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
repo_root=$(km_git_ancestor) || {
  emit ERROR doctor "no git repository found from $(pwd -P); no section can run"
  exit 3
}

WORKDIR="$(mktemp -d -t knowledge-doctor-XXXXXX)"
cleanup() { rm -rf "$WORKDIR" 2>/dev/null || true; }
trap cleanup EXIT

STORE=""

section_docs
section_memory
section_locks
section_context
section_agents_md
section_capability_matrix

[ "$HAS_FINDING" -eq 0 ] && exit 0
exit 1
