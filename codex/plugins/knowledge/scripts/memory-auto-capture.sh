#!/usr/bin/env bash
# memory-auto-capture.sh — knowledge 0.3 autonomous-capture ENFORCEMENT wrapper
# (shared, byte-identical across providers). The capture flow — the Claude opt-in
# `type:"prompt"` Stop hook (assets/capture-stop-hook.md), or a manual staging
# pass — asks the AGENT for one bounded capture; the agent stages 0-N structured
# candidates and routes them THROUGH THIS WRAPPER. The wrapper is the single
# enforcement point:
# it caps count/bytes, rejects secrets, does a cheap duplicate check, and then
# delegates each ACCEPTED candidate to `memory-remember.sh --staged` — the ONLY
# writer path it ever invokes.
#
# It NEVER inspects a transcript, NEVER decides what is memory-worthy (the model
# does that), NEVER calls any other writer subcommand (apply/index/retire/purge/
# bootstrap), and NEVER edits MEMORY.md, authoritative memory files, docs,
# context snapshots, trackers, or AGENTS.md. Every write lands ONLY in
# `.agents/memory/.inbox/<sha256>.md` via the delegated writer; `/consolidate`
# remains the human/agent persist gate.
#
# Usage:
#   memory-auto-capture.sh [--store <path>] --batch-dir <dir>
#   memory-auto-capture.sh [--store <path>] --staged <file> [--staged <file> ...]
#
# `--batch-dir` accepts a directory of staged candidate files (*.md, processed
# in C-locale name order). `--staged` names individual staged files (repeatable).
# `--store` is optional and resolves exactly like the other surfaces when omitted.
#
# Env tunables:
#   KNOWLEDGE_AUTO_CAPTURE_LIMIT        max candidates ACCEPTED per pass (default 3)
#   KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING  skip the whole pass when the inbox already
#                                       holds >= this many pending candidates (default 20)
#   KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES    hard per-candidate raw-byte cap (default 4096)
#
# NOTE: this wrapper has no opt-in gate of its own. Whether a capture pass is
# REQUESTED is decided upstream — on Claude by the presence of the opt-in
# `type:"prompt"` Stop-hook snippet (assets/capture-stop-hook.md); the retired
# 0.3.0/0.3.1 KNOWLEDGE_AUTO_CAPTURE env gate no longer governs anything.
# Invoking this wrapper is an explicit act of capture (like memory-remember.sh),
# so it always runs when called.
#
# Output: accepted candidates print `captured: <capture_id>` to stdout, one per
# line; all warnings/rejections/summaries go to stderr. Exit codes: 0 ok (incl.
# zero candidates and skipped-because-full); 2 usage; 6 reviewer-role refusal
# (propagated from the writer, hard stop). Store-resolution/unsafe-store failures
# FAIL SAFE: a note to stderr, no write, exit 0. Caps FAIL CLOSED (skip/reject,
# never delete). Zero network egress.
# Supported platforms: macOS, Linux.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
WRITER="$HERE/memory-write.sh"
# shellcheck source=memory-write.sh
source "$WRITER"                       # for km_parse_capture (dispatch is guarded when sourced)
REMEMBER="$HERE/memory-remember.sh"

_kac_usage() {
  echo "ERROR: Usage: memory-auto-capture.sh [--store <path>] --batch-dir <dir>" >&2
  echo "       memory-auto-capture.sh [--store <path>] --staged <file> [--staged <file> ...]" >&2
}

# ---- arg parse -------------------------------------------------------------
store_arg="" batch_dir="" have_batch=0
staged_files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --store)
      [ $# -ge 2 ] || { echo "ERROR: --store requires a value" >&2; exit 2; }
      store_arg="$2"; shift 2 ;;
    --batch-dir)
      [ $# -ge 2 ] || { echo "ERROR: --batch-dir requires a value" >&2; exit 2; }
      batch_dir="$2"; have_batch=1; shift 2 ;;
    --staged)
      [ $# -ge 2 ] || { echo "ERROR: --staged requires a value" >&2; exit 2; }
      staged_files+=("$2"); shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; _kac_usage; exit 2 ;;
  esac
done

if [ "$have_batch" -eq 1 ] && [ "${#staged_files[@]}" -gt 0 ]; then
  echo "ERROR: --batch-dir and --staged are mutually exclusive" >&2; exit 2
fi
if [ "$have_batch" -eq 0 ] && [ "${#staged_files[@]}" -eq 0 ]; then
  _kac_usage; exit 2
fi

# Collect the candidate list (C-locale name order for determinism).
candidates=()
if [ "$have_batch" -eq 1 ]; then
  if [ ! -d "$batch_dir" ] || [ -L "$batch_dir" ]; then
    echo "ERROR: --batch-dir is not a directory: $batch_dir" >&2; exit 2
  fi
  while IFS= read -r f; do
    [ -n "$f" ] && candidates+=("$f")
  done < <(find "$batch_dir" -mindepth 1 -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
else
  candidates=("${staged_files[@]}")
fi

# Zero candidates is a valid, silent success (A4).
if [ "${#candidates[@]}" -eq 0 ]; then
  exit 0
fi

# ---- tunables --------------------------------------------------------------
LIMIT="${KNOWLEDGE_AUTO_CAPTURE_LIMIT:-3}"
MAX_PENDING="${KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING:-20}"
MAX_BYTES="${KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES:-4096}"
case "$LIMIT"       in ''|*[!0-9]*) LIMIT=3 ;;     esac
case "$MAX_PENDING" in ''|*[!0-9]*) MAX_PENDING=20 ;; esac
case "$MAX_BYTES"   in ''|*[!0-9]*) MAX_BYTES=4096 ;; esac

# ---- resolve store (fail SAFE: no store -> no write, exit 0) ---------------
store="$(km_resolve_store "$store_arg" 2>/dev/null)" || {
  echo "auto-capture: no resolvable knowledge store; nothing captured" >&2; exit 0
}
if [ -z "$store" ] || [ ! -d "$store" ] || [ -L "$store" ]; then
  echo "auto-capture: store is missing or unsafe; nothing captured" >&2; exit 0
fi

# ---- MAX_PENDING gate (A7): fail CLOSED = skip whole pass, never delete ----
pending="$(bash "$REMEMBER" --store "$store" --list 2>/dev/null | grep -c . || true)"
case "$pending" in ''|*[!0-9]*) pending=0 ;; esac
if [ "$pending" -ge "$MAX_PENDING" ]; then
  echo "auto-capture: inbox already holds ${pending} pending candidate(s) (>= MAX_PENDING=${MAX_PENDING}); skipping capture — run /knowledge:consolidate to clear it. Nothing captured or deleted." >&2
  exit 0
fi

# ---- helpers ---------------------------------------------------------------
# Normalize a string for cheap comparison: lowercase, strip surrounding quotes,
# trim, collapse internal whitespace. bash 3.2 safe (tr + parameter expansion).
_kac_norm() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')"
  s="${s#\"}"; s="${s%\"}"
  s="${s# }"; s="${s% }"
  printf '%s' "$s"
}

# Pull proposed.<key> out of the arrays km_parse_capture populates.
_kac_proposed() {
  local key="proposed.$1" i
  for ((i = 0; i < ${#KM_CAP_PROPOSED_NAMES[@]}; i++)); do
    if [ "${KM_CAP_PROPOSED_NAMES[$i]}" = "$key" ]; then
      printf '%s' "${KM_CAP_PROPOSED_VALUES[$i]}"; return 0
    fi
  done
  return 1
}

# Deterministic secret scanner (A11): named fixtures only, no broad-PII claim.
# PEM private-key blocks, GitHub PATs (ghp_), OpenAI-style keys (sk-), AWS
# access-key IDs (AKIA...). Returns 0 if a secret is present.
_kac_has_secret() {
  LC_ALL=C grep -Eq -e '-----BEGIN[A-Z ]*PRIVATE KEY-----' \
                    -e 'ghp_[A-Za-z0-9]{20,}' \
                    -e 'sk-[A-Za-z0-9]{16,}' \
                    -e 'AKIA[0-9A-Z]{16}' "$1" 2>/dev/null
}

# Build the set of already-known normalized names + descriptions, from the
# authoritative store files (top-level name:/description:) and the pending inbox
# candidates (proposed.name/description). One newline-delimited blob each.
known_names=""
known_descs=""
_kac_collect_known() {
  local f nm ds
  # authoritative store files (top-level frontmatter keys)
  for f in "$store"/*.md; do
    [ -f "$f" ] || continue
    nm="$(LC_ALL=C grep -m1 '^name:' "$f" 2>/dev/null | sed 's/^name:[[:space:]]*//')"
    ds="$(LC_ALL=C grep -m1 '^description:' "$f" 2>/dev/null | sed 's/^description:[[:space:]]*//')"
    [ -n "$nm" ] && known_names="${known_names}$(_kac_norm "$nm")"$'\n'
    [ -n "$ds" ] && known_descs="${known_descs}$(_kac_norm "$ds")"$'\n'
  done
  # pending inbox candidates (staged envelope -> proposed.*)
  local inbox="$store/.inbox"
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || return 0
  for f in "$inbox"/*.md; do
    [ -f "$f" ] || continue
    if km_parse_capture "$f" stored >/dev/null 2>&1; then
      nm="$(_kac_proposed name || true)"
      ds="$(_kac_proposed description || true)"
      [ -n "$nm" ] && known_names="${known_names}$(_kac_norm "$nm")"$'\n'
      [ -n "$ds" ] && known_descs="${known_descs}$(_kac_norm "$ds")"$'\n'
    fi
  done
}
_kac_collect_known

# ---- process candidates ----------------------------------------------------
total="${#candidates[@]}"
accepted=0
rejected=0
i=0
for cand in "${candidates[@]}"; do
  i=$((i + 1))

  # LIMIT (A6): accept at most LIMIT; the rest are rejected with a visible count
  # (never silently truncated).
  if [ "$accepted" -ge "$LIMIT" ]; then
    rejected=$((rejected + 1))
    continue
  fi

  if [ ! -f "$cand" ] || [ -L "$cand" ]; then
    echo "auto-capture: skipping non-file candidate: $cand" >&2
    rejected=$((rejected + 1)); continue
  fi

  # MAX_BYTES (A8): fail closed.
  bytes="$(wc -c < "$cand" 2>/dev/null | tr -d ' ')"
  case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  if [ "$bytes" -gt "$MAX_BYTES" ]; then
    echo "auto-capture: rejecting oversized candidate ($bytes > MAX_BYTES=$MAX_BYTES bytes): $cand" >&2
    rejected=$((rejected + 1)); continue
  fi

  # Secret scan (A11).
  if _kac_has_secret "$cand"; then
    echo "auto-capture: rejecting candidate containing a secret pattern: $cand" >&2
    rejected=$((rejected + 1)); continue
  fi

  # Shape validation + cheap duplicate check (A10, A19). A malformed candidate
  # fails to parse here and is rejected with NO write (the wrapper's own
  # no-write proof); grammar is re-validated authoritatively by the writer.
  if ! km_parse_capture "$cand" staged >/dev/null 2>&1; then
    echo "auto-capture: rejecting malformed candidate (bad capture grammar): $cand" >&2
    rejected=$((rejected + 1)); continue
  fi
  cand_name="$(_kac_proposed name || true)"
  cand_desc="$(_kac_proposed description || true)"
  n_name="$(_kac_norm "$cand_name")"
  n_desc="$(_kac_norm "$cand_desc")"
  if { [ -n "$n_name" ] && printf '%s' "$known_names" | LC_ALL=C grep -qxF "$n_name"; } \
     || { [ -n "$n_desc" ] && printf '%s' "$known_descs" | LC_ALL=C grep -qxF "$n_desc"; }; then
    echo "auto-capture: skipping duplicate (name/description already pending or indexed): ${cand_name:-$cand}" >&2
    rejected=$((rejected + 1)); continue
  fi

  # Delegate the actual write to the sole writer path.
  out="$(bash "$REMEMBER" --store "$store" --staged "$cand" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 6 ]; then
    echo "auto-capture: reviewer-role refusal from the writer; aborting the pass (nothing further captured)." >&2
    exit 6
  fi
  if [ "$rc" -ne 0 ]; then
    echo "auto-capture: writer rejected candidate (rc=$rc): $cand" >&2
    rejected=$((rejected + 1)); continue
  fi

  cid="$(printf '%s\n' "$out" | grep -m1 '^capture_id: ' | sed 's/^capture_id: //')"
  printf 'captured: %s\n' "${cid:-unknown}"
  accepted=$((accepted + 1))
  # Track within-pass so a later duplicate in the same batch is also caught.
  [ -n "$n_name" ] && known_names="${known_names}${n_name}"$'\n'
  [ -n "$n_desc" ] && known_descs="${known_descs}${n_desc}"$'\n'
done

if [ "$total" -gt "$LIMIT" ]; then
  echo "auto-capture: received $total candidate(s); accepted up to LIMIT=$LIMIT, rejected $rejected (overflow not silently dropped)." >&2
fi
echo "auto-capture: ${accepted} candidate(s) queued to the inbox, ${rejected} rejected. Run /knowledge:consolidate to review and persist." >&2
exit 0
