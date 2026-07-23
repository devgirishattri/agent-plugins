#!/usr/bin/env bash
# memory-remember.sh — capture PLANNER/NORMALIZER.
# Implements the remember surface plus the capture grammar inside the
# single-writer contract.
#
# This script never mutates the store directly. For `--staged`, it validates
# the staged semantic candidate against the closed lexical subset (for
# better error messages at plan time — the writer remains the sole
# authority and re-validates unconditionally), derives the idempotency key
# exactly per the canonical length-delimited encoding, and delegates the
# actual write to `memory-write.sh capture`, propagating its exit code
# unchanged. To guarantee the key is computed by the IDENTICAL algorithm the
# writer re-derives it with (never a second implementation to drift), this
# script sources memory-write.sh (a documented-safe operation: its dispatch
# block is guarded by `"${BASH_SOURCE[0]}" = "${0}"`, which is false when
# sourced, so no subcommand ever runs as a side effect of sourcing) and
# reuses its `km_parse_capture` / `km_capture_canonical_hash` functions
# rather than reimplementing the encoding. The actual write still goes
# through a real `bash memory-write.sh capture ...` subprocess, exactly
# mirroring init.sh's plan-then-delegate pattern, so every writer-side
# guarantee (reviewer refusal, store hardening, locking, CAS) applies
# unchanged.
#
# `--list` is a separate, read-only mode: it never invokes memory-write.sh
# as a writer and takes no lock. Expiry is computed at READ time from each
# candidate's stamped `created` plus `KNOWLEDGE_INBOX_RETENTION_DAYS`
# (default 30) — this script never touches a candidate file to mark it.
# For byte-for-byte agreement with `memory-write.sh purge --expired`'s own
# plan-mode selection (the id column here is what feeds `purge --ids`),
# `--list` reuses the writer's own (sourced) candidate-age/verdict helpers
# rather than a second age-computation implementation.
#
# Usage:
#   memory-remember.sh [--store <path>] --staged <file>
#   memory-remember.sh [--store <path>] --list [--expired-only]
#
# `--store <path>` is optional in both modes: omitted, it resolves via the
# ONE common resolver (explicit > KNOWLEDGE_MEMORY_HOME > canonical
# discovery under <repo-root>/.agents/memory/), identically to
# memory-lint.sh/memory-index.sh — the resolved, canonicalized path is what
# gets passed on to `memory-write.sh capture --store <resolved>`.
#
# --list output: one row per candidate, tab-separated,
#   <id>\t<created>\t<age-days>\t<expired|active>\t<sensitivity>
# in id order (C locale). An absent `.inbox/` is zero candidates (exit 0,
# empty stdout) — not an error.
#
# Exit codes (shared map): 0 ok; 2 usage (this script's own argv errors, or
#   a --staged validation failure caught at plan level, or a delegated
#   writer usage/validation exit propagated unchanged); 3 store-resolution
#   failure; 4 store-integrity (this script's own `.inbox` reserved-name
#   check for --list, or propagated from the writer for --staged); 5 store
#   locked-or-recovery-busy (propagated from the writer, --staged only);
#   6 reviewer-role refusal (propagated from the writer, --staged only —
#   --list performs no role check, matching the read-anywhere rule shared
#   by lint/index/search/graph).
# Supported platforms: macOS, Linux
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
WRITER="$HERE/memory-write.sh"
# shellcheck source=memory-write.sh
source "$WRITER"

_kr_usage() {
  echo "ERROR: Usage: memory-remember.sh [--store <path>] --staged <file>" >&2
  echo "       memory-remember.sh [--store <path>] --list [--expired-only]" >&2
}

store_arg="" staged_file="" list_mode=0 expired_only=0
have_staged=0 have_list=0

while [ $# -gt 0 ]; do
  case "$1" in
    --store)
      [ $# -ge 2 ] || { echo "ERROR: --store requires a value" >&2; exit 2; }
      store_arg="$2"
      shift 2
      ;;
    --staged)
      [ $# -ge 2 ] || { echo "ERROR: --staged requires a value" >&2; exit 2; }
      staged_file="$2"
      have_staged=1
      shift 2
      ;;
    --list)
      list_mode=1
      have_list=1
      shift 1
      ;;
    --expired-only)
      expired_only=1
      shift 1
      ;;
    *)
      _kr_usage
      exit 2
      ;;
  esac
done

if [ "$have_staged" -eq 1 ] && [ "$have_list" -eq 1 ]; then
  echo "ERROR: --staged and --list are mutually exclusive" >&2
  exit 2
fi
if [ "$have_staged" -eq 0 ] && [ "$have_list" -eq 0 ]; then
  _kr_usage
  exit 2
fi
if [ "$expired_only" -eq 1 ] && [ "$have_list" -eq 0 ]; then
  echo "ERROR: --expired-only requires --list" >&2
  exit 2
fi

store=$(km_resolve_store "$store_arg") || exit $?

# ---------------------------------------------------------------------------
# --list: read-only. Never creates `.inbox/` — a read surface must not
# mutate the store as a side effect of listing.
# ---------------------------------------------------------------------------
if [ "$list_mode" -eq 1 ]; then
  inbox="$store/.inbox"

  # Reserved-name safety, read-only mirror of the writer's own
  # _km_ensure_inbox_dir checks (symlink/non-directory/foreign-owner/
  # wrong-mode) but WITHOUT the mkdir side effect: absent is zero
  # candidates, not a defect.
  if [ ! -e "$inbox" ] && [ ! -L "$inbox" ]; then
    exit 0
  fi
  if [ -L "$inbox" ] || [ ! -d "$inbox" ]; then
    km_error ".inbox exists but is not a safe directory: $inbox"
    exit 4
  fi
  inbox_owner=$(km_path_uid "$inbox") || { km_error "cannot inspect .inbox ownership: $inbox"; exit 4; }
  if [ "$inbox_owner" != "$(id -u)" ]; then
    km_error ".inbox has a foreign owner: $inbox"
    exit 4
  fi
  inbox_mode=$(km_path_mode "$inbox") || { km_error "cannot inspect .inbox mode: $inbox"; exit 4; }
  if [ "$inbox_mode" != "700" ]; then
    km_error ".inbox must be mode 700 (found $inbox_mode): $inbox"
    exit 4
  fi

  retention_days="${KNOWLEDGE_INBOX_RETENTION_DAYS:-30}"
  now_epoch=$(date -u +%s)

  find "$inbox" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null | while IFS= read -r f; do
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    cid=$(basename "$f" .md)
    created="" sensitivity=""
    if km_parse_capture "$f" stored >/dev/null 2>&1; then
      created="$KM_CAP_CREATED"
      sensitivity="$KM_CAP_SENSITIVITY"
    else
      # Unparseable candidate (should not occur for a writer-produced
      # file): fall back to a raw created: read so age/verdict can still
      # be computed; sensitivity is left blank rather than guessed.
      created=$(_km_candidate_created "$f")
    fi
    verdict=$(_km_candidate_verdict "$created" "$retention_days")
    if [ "$expired_only" -eq 1 ] && [ "$verdict" != "expired" ]; then
      continue
    fi
    age_days=0
    if [ -n "$created" ]; then
      created_epoch=$(_km_iso_to_epoch "$created" 2>/dev/null) && [ -n "$created_epoch" ] \
        && age_days=$(( (now_epoch - created_epoch) / 86400 ))
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$cid" "$created" "$age_days" "$verdict" "$sensitivity"
  done | LC_ALL=C sort
  exit 0
fi

# ---------------------------------------------------------------------------
# --staged: plan-level validation, then delegate the write.
# ---------------------------------------------------------------------------
km_parse_capture "$staged_file" staged || exit 2
idemp_key=$(km_capture_canonical_hash) || exit 2
if ! [[ "$idemp_key" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: cannot compute a valid capture idempotency key (sha256 tool unavailable?)" >&2
  exit 4
fi

bash "$WRITER" capture --store "$store" --staged "$staged_file" --idempotency-key "$idemp_key"
exit $?
