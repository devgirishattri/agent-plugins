#!/usr/bin/env bash
# memory-write.sh — THE single store-mutation helper for the knowledge
# plugin's memory module (KNOWLEDGE_PLUGIN_SPEC.md "Single-writer contract").
# The ONLY code path that mutates a memory store, its MEMORY.md, or the
# capture inbox. Every subcommand's argv is exact and exhaustive; anything
# else is exit 2.
#
# Usage:
#   memory-write.sh capture   --store <path> --staged <file> --idempotency-key <sha256>
#   memory-write.sh apply     --store <path> --target <basename>.md --staged-target <file>
#                              --staged-index <file> --expect-target <sha256|absent>
#                              --expect-index <sha256>
#                              [--candidate <capture-id> --expect-candidate <sha256>]
#   memory-write.sh index     --store <path> --staged-index <file> --expect-index <sha256>
#   memory-write.sh retire    --store <path> --slug <slug> --staged-index <file>
#                              --expect-target <sha256> --expect-index <sha256>
#                              --confirm <path>
#   memory-write.sh purge     --store <path> (--ids <id,...> | --expired)
#                              [--manifest <file>] --confirm <path>
#   memory-write.sh bootstrap --store <path>
#   memory-write.sh unlock    --store <path> --confirm <path>
#
# Exit codes (shared map): 0 ok / 2 usage / 3 store-resolution / 4 store-
# integrity / 5 store locked-or-recovery-busy / 6 role refusal.
#
# Test-only hooks (INERT unless the env var is set — never touch these in
# normal operation): KNOWLEDGE_TEST_DIE_AT_STEP=<step> exits 137 immediately
# after completing the named numbered step of the apply/retire/index
# transaction (2,3,4,5,6,7,8,9,10); KNOWLEDGE_TEST_DIE_AT_RECOVERY_POINT=<pt>
# exits 137 at a named point inside recovery (forward:pre-candidate,
# forward:pre-cleanup, rollback:pre-target, rollback:pre-index,
# rollback:pre-verify, rollback:pre-cleanup); KNOWLEDGE_TEST_LOCK_RETRY_MAX /
# KNOWLEDGE_TEST_LOCK_RETRY_DELAY shorten the lock-contention retry loop so
# contention tests do not need to wait out the real ~10s bound;
# KNOWLEDGE_TEST_DIE_AFTER_PURGE_ID=<candidate-id> exits 137 immediately
# after that candidate is unlinked in `purge`'s apply-mode sequence, to
# simulate an interruption leaving a validated prefix purged.
# Supported platforms: macOS, Linux
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
KM_SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Test-only kill hooks (see header). Inert unless the env var is set.
# ---------------------------------------------------------------------------
_km_maybe_die() {
  local step="$1"
  if [ -n "${KNOWLEDGE_TEST_DIE_AT_STEP:-}" ] && [ "${KNOWLEDGE_TEST_DIE_AT_STEP}" = "$step" ]; then
    exit 137
  fi
}

_km_maybe_die_recovery() {
  local point="$1"
  if [ -n "${KNOWLEDGE_TEST_DIE_AT_RECOVERY_POINT:-}" ] && [ "${KNOWLEDGE_TEST_DIE_AT_RECOVERY_POINT}" = "$point" ]; then
    exit 137
  fi
}

_km_in_list() {
  local needle="$1" hay="$2" w
  for w in $hay; do
    [ "$w" = "$needle" ] && return 0
  done
  return 1
}

# _km_is_safe_bare_component <name>
# True iff name is safe to use as a single, store-relative bare path
# component (never a path fragment): non-empty, no "/" or "\", and not "."
# or ".." (whole-name traversal components). This is the containment
# primitive behind retire's --slug argument (which, unlike apply's
# --target, carries no ".md" suffix or reserved-name literal to piggyback
# a bare-basename check on, so it gets its own explicit gate). Does NOT
# check reserved names or existence — callers layer those on top.
_km_is_safe_bare_component() {
  local name="$1"
  [ -n "$name" ] || return 1
  case "$name" in
    */* | *'\'*) return 1 ;;
    "." | "..") return 1 ;;
  esac
  return 0
}

# _km_validate_ids_csv <csv>
# purge --ids values are content-addressed candidate ids: exactly 64
# lowercase hex characters each, comma-separated, no empty segments
# (leading/trailing/double commas). Rejected BEFORE any id is ever used to
# build a `.inbox/<id>.md` path — an id containing "/" or ".." would
# otherwise let --ids traverse outside .inbox the same way an unvalidated
# retire --slug could traverse outside the store.
_km_validate_ids_csv() {
  local csv="$1"
  [ -n "$csv" ] || return 1
  case "$csv" in
    ","* | *"," | *",,"*) return 1 ;;
  esac
  local -a parts=()
  IFS=',' read -r -a parts <<< "$csv"
  [ "${#parts[@]}" -gt 0 ] || return 1
  local p pi
  for ((pi = 0; pi < ${#parts[@]}; pi++)); do
    p="${parts[pi]}"
    [[ "$p" =~ ^[0-9a-f]{64}$ ]] || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Store lock: hard-linked <store>/.lock, identity = inode (see spec's
# apply-transaction contract, step 1).
# ---------------------------------------------------------------------------
_km_lock_acquire() {
  local store="$1" pid="$$" nonce ts claim attempt=0
  local lock="$store/.lock"
  local max_attempts="${KNOWLEDGE_TEST_LOCK_RETRY_MAX:-50}"
  local delay="${KNOWLEDGE_TEST_LOCK_RETRY_DELAY:-0.2}"

  nonce=$(km_random_hex32) || { km_error "cannot generate lock nonce"; return 4; }
  ts=$(km_now_utc)
  claim="$store/.lock.claim.${pid}.${nonce}"

  if ! (
    umask 077
    set -o noclobber
    printf 'pid: %s\ntimestamp: %s\nnonce: %s\n' "$pid" "$ts" "$nonce" > "$claim"
  ) 2>/dev/null; then
    km_error "cannot create lock claim file: $claim"
    return 4
  fi
  chmod 600 "$claim" 2>/dev/null || true

  while :; do
    if ln "$claim" "$lock" 2>/dev/null; then
      KM_LOCK_CLAIM="$claim"
      return 0
    fi
    if [ ! -e "$lock" ]; then
      rm -f "$claim" 2>/dev/null || true
      km_error "cannot acquire store lock (unexpected failure): $lock"
      return 4
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max_attempts" ]; then
      local holder="(unreadable)"
      [ -f "$lock" ] && holder=$(cat "$lock" 2>/dev/null)
      echo "store locked: $lock" >&2
      printf '%s\n' "$holder" >&2
      echo "run: bash $KM_SELF unlock --store $store --confirm $store" >&2
      local lc
      lc=$(km_link_count "$claim" 2>/dev/null || echo "")
      [ "$lc" = "1" ] && rm -f "$claim" 2>/dev/null
      return 5
    fi
    sleep "$delay"
  done
}

_km_lock_release() {
  local store="$1" claim="${KM_LOCK_CLAIM:-}"
  local lock="$store/.lock"
  [ -n "$claim" ] || return 0
  local lock_id claim_id
  lock_id=$(km_path_identity "$lock" 2>/dev/null) || lock_id=""
  claim_id=$(km_path_identity "$claim" 2>/dev/null) || claim_id=""
  if [ -n "$lock_id" ] && [ "$lock_id" = "$claim_id" ]; then
    rm -f "$lock" 2>/dev/null || true
    rm -f "$claim" 2>/dev/null || true
  fi
  KM_LOCK_CLAIM=""
}

_km_sweep_dead_generations() {
  local store="$1" f
  find "$store" -mindepth 1 -maxdepth 1 -name '.journal.tmp.*' 2>/dev/null | while IFS= read -r f; do
    rm -rf "$f"
  done
  find "$store" -mindepth 1 -maxdepth 1 -name '.staged.*' 2>/dev/null | while IFS= read -r f; do
    rm -rf "$f"
  done
}

# ---------------------------------------------------------------------------
# Journal meta (LITERAL serialization, exact key order — see spec).
# ---------------------------------------------------------------------------
_KM_META_KEYS="version target marker before_target before_index after_target after_index candidate_id candidate_raw_sha staged_dir pid timestamp"

_km_meta_get() {
  local meta="$1" key="$2" line
  line=$(grep -m1 "^${key}: " "$meta" 2>/dev/null) || return 1
  printf '%s\n' "${line#"${key}": }"
}

_km_meta_validate_grammar() {
  local meta="$1" i=1 key line total
  for key in $_KM_META_KEYS; do
    line=$(sed -n "${i}p" "$meta" 2>/dev/null)
    case "$line" in
      "${key}:"*) : ;;
      *)
        km_error "journal meta key/order mismatch at line $i (expected $key): $meta"
        return 4
        ;;
    esac
    i=$((i + 1))
  done
  total=$(wc -l < "$meta" 2>/dev/null | tr -d ' ')
  if [ "$total" != "12" ]; then
    km_error "journal meta has unexpected line count ($total): $meta"
    return 4
  fi
  return 0
}

_km_consume_candidate() {
  local store="$1" candidate_id="$2" expect_raw_sha="$3" cfile raw
  [ "$candidate_id" != "-" ] || return 0
  cfile="$store/.inbox/${candidate_id}.md"
  if [ ! -e "$cfile" ]; then
    return 0
  fi
  if [ -L "$cfile" ] || [ ! -f "$cfile" ]; then
    km_error "candidate path is unsafe during consumption: $cfile"
    return 4
  fi
  raw=$(km_sha256_file "$cfile")
  if [ "$raw" != "$expect_raw_sha" ]; then
    km_error "candidate changed since approval; retaining for inspection: $cfile"
    return 4
  fi
  rm -f "$cfile"
  return 0
}

# ---------------------------------------------------------------------------
# Recovery: roll forward if both legs already match AAFTER, else roll back to
# BEFORE. Crash-idempotent; never consumes the before-* backups.
# ---------------------------------------------------------------------------
_km_run_recovery() {
  local store="$1" jd meta target marker
  local before_target before_index after_target after_index
  local candidate_id candidate_raw_sha staged_dir
  jd="$store/.journal"
  meta="$jd/meta"
  [ -d "$jd" ] || return 0

  find "$jd" -mindepth 1 -maxdepth 1 -name 'restore.tmp.*' 2>/dev/null | while IFS= read -r f; do
    rm -rf "$f"
  done

  _km_meta_validate_grammar "$meta" || return 4
  target=$(_km_meta_get "$meta" target) || { km_error "unreadable journal meta: $meta"; return 4; }
  marker=$(_km_meta_get "$meta" marker) || return 4
  before_target=$(_km_meta_get "$meta" before_target) || return 4
  before_index=$(_km_meta_get "$meta" before_index) || return 4
  after_target=$(_km_meta_get "$meta" after_target) || return 4
  after_index=$(_km_meta_get "$meta" after_index) || return 4
  candidate_id=$(_km_meta_get "$meta" candidate_id) || return 4
  candidate_raw_sha=$(_km_meta_get "$meta" candidate_raw_sha) || return 4
  staged_dir=$(_km_meta_get "$meta" staged_dir) || return 4

  local target_path=""
  [ "$target" != "NONE" ] && target_path="$store/$target"

  local committed=1
  case "$after_index" in
    "HASH "*)
      [ "$(km_sha256_file "$store/MEMORY.md" 2>/dev/null)" = "${after_index#HASH }" ] || committed=0
      ;;
    *) committed=0 ;;
  esac
  if [ "$committed" -eq 1 ]; then
    case "$marker" in
      HASH)
        [ "$(km_sha256_file "$target_path" 2>/dev/null)" = "${after_target#HASH }" ] || committed=0
        ;;
      ABSENT)
        [ ! -e "$target_path" ] || committed=0
        ;;
      NONE) : ;;
    esac
  fi

  if [ "$committed" -eq 1 ]; then
    _km_maybe_die_recovery "forward:pre-candidate"
    if [ "$candidate_id" != "-" ]; then
      _km_consume_candidate "$store" "$candidate_id" "$candidate_raw_sha" || return 4
    fi
    _km_maybe_die_recovery "forward:pre-cleanup"
    rm -rf "${store:?}/${staged_dir:?}" 2>/dev/null || true
    rm -rf "$jd"
    return 0
  fi

  _km_maybe_die_recovery "rollback:pre-target"
  case "$before_target" in
    "HASH "*)
      local tmp_r
      tmp_r="$jd/restore.tmp.$$.$(km_random_hex32)"
      cp "$jd/before-target" "$tmp_r" && chmod 600 "$tmp_r" 2>/dev/null
      mv -f "$tmp_r" "$target_path" || { km_error "cannot restore target leg"; return 4; }
      ;;
    ABSENT)
      rm -f "$target_path" 2>/dev/null || true
      ;;
    NONE) : ;;
  esac

  _km_maybe_die_recovery "rollback:pre-index"
  local tmp_i
  tmp_i="$jd/restore.tmp.$$.$(km_random_hex32)"
  cp "$jd/before-index" "$tmp_i" && chmod 600 "$tmp_i" 2>/dev/null
  mv -f "$tmp_i" "$store/MEMORY.md" || { km_error "cannot restore index leg"; return 4; }

  _km_maybe_die_recovery "rollback:pre-verify"
  case "$before_target" in
    "HASH "*)
      [ "$(km_sha256_file "$target_path" 2>/dev/null)" = "${before_target#HASH }" ] || {
        km_error "rollback verification failed for target leg"
        return 4
      }
      ;;
    ABSENT)
      [ ! -e "$target_path" ] || {
        km_error "rollback verification failed (target should be absent)"
        return 4
      }
      ;;
  esac
  [ "$(km_sha256_file "$store/MEMORY.md" 2>/dev/null)" = "${before_index#HASH }" ] || {
    km_error "rollback verification failed for index leg"
    return 4
  }

  _km_maybe_die_recovery "rollback:pre-cleanup"
  rm -rf "${store:?}/${staged_dir:?}" 2>/dev/null || true
  rm -rf "$jd"
  return 0
}

# ---------------------------------------------------------------------------
# apply/retire/index shared transaction (spec: "apply transaction contract").
# marker: HASH (apply) | ABSENT (retire) | NONE (index)
# ---------------------------------------------------------------------------
_km_transaction_body() {
  local store="$1" target="$2" marker="$3" staged_target="$4" staged_index="$5"
  local expect_target="$6" expect_index="$7" candidate_id="$8" expect_candidate="$9"

  _km_sweep_dead_generations "$store"
  if [ -d "$store/.journal" ]; then
    _km_run_recovery "$store" || return 4
  fi
  _km_maybe_die "2"

  # (3) SEAL
  local nonce staged_dir sealed_index sealed_target=""
  nonce=$(km_random_hex32) || { km_error "cannot generate generation nonce"; return 4; }
  staged_dir=".staged.$$.${nonce}"
  ( umask 077; mkdir -m 700 "${store:?}/${staged_dir:?}" ) || { km_error "cannot create staged dir"; return 4; }
  sealed_index="$store/$staged_dir/index.md"
  if ! cp "$staged_index" "$sealed_index" 2>/dev/null || ! chmod 600 "$sealed_index" 2>/dev/null; then
    km_error "cannot seal staged index input"
    rm -rf "${store:?}/${staged_dir:?}"
    return 4
  fi
  if [ "$marker" = "HASH" ]; then
    sealed_target="$store/$staged_dir/target.md"
    if ! cp "$staged_target" "$sealed_target" 2>/dev/null || ! chmod 600 "$sealed_target" 2>/dev/null; then
      km_error "cannot seal staged target input"
      rm -rf "${store:?}/${staged_dir:?}"
      return 4
    fi
  fi
  _km_maybe_die "3"

  # (4) VERIFY: candidate first (fail closed BEFORE the journal), then CAS hashes
  if [ "$candidate_id" != "-" ]; then
    local cfile="$store/.inbox/${candidate_id}.md" craw
    if [ ! -f "$cfile" ] || [ -L "$cfile" ]; then
      km_error "candidate not found or unsafe: $cfile"
      rm -rf "${store:?}/${staged_dir:?}"
      return 4
    fi
    craw=$(km_sha256_file "$cfile")
    if [ "$craw" != "$expect_candidate" ]; then
      km_error "candidate hash mismatch (changed since approval): $cfile"
      rm -rf "${store:?}/${staged_dir:?}"
      return 4
    fi
  fi

  local before_index_hash
  before_index_hash=$(km_sha256_file "$store/MEMORY.md")
  if [ "$before_index_hash" != "$expect_index" ]; then
    km_error "index CAS mismatch (MEMORY.md changed since approval)"
    rm -rf "${store:?}/${staged_dir:?}"
    return 4
  fi

  local target_path="" before_target_state
  if [ "$target" != "NONE" ]; then
    target_path="$store/$target"
    if [ -f "$target_path" ] && [ ! -L "$target_path" ]; then
      before_target_state="HASH $(km_sha256_file "$target_path")"
    else
      before_target_state="ABSENT"
    fi
    if [ "$expect_target" = "absent" ]; then
      if [ "$before_target_state" != "ABSENT" ]; then
        km_error "target CAS mismatch (expected absent, file exists)"
        rm -rf "${store:?}/${staged_dir:?}"
        return 4
      fi
    else
      if [ "$before_target_state" != "HASH $expect_target" ]; then
        km_error "target CAS mismatch (changed since approval)"
        rm -rf "${store:?}/${staged_dir:?}"
        return 4
      fi
    fi
  else
    before_target_state="NONE"
  fi
  _km_maybe_die "4"

  # (5) JOURNAL
  local jgen=".journal.tmp.$$.${nonce}"
  ( umask 077; mkdir -m 700 "${store:?}/${jgen:?}" ) || {
    km_error "cannot build journal"
    rm -rf "${store:?}/${staged_dir:?}"
    return 4
  }
  if [ "$before_target_state" != "NONE" ] && [ "$before_target_state" != "ABSENT" ]; then
    if ! cp "$target_path" "$store/$jgen/before-target" || ! chmod 600 "$store/$jgen/before-target" 2>/dev/null; then
      km_error "cannot back up target leg"
      rm -rf "${store:?}/${jgen:?}" "${store:?}/${staged_dir:?}"
      return 4
    fi
  fi
  if ! cp "$store/MEMORY.md" "$store/$jgen/before-index" || ! chmod 600 "$store/$jgen/before-index" 2>/dev/null; then
    km_error "cannot back up index leg"
    rm -rf "${store:?}/${jgen:?}" "${store:?}/${staged_dir:?}"
    return 4
  fi

  local after_index_hash after_target_state
  after_index_hash=$(km_sha256_file "$sealed_index")
  case "$marker" in
    HASH) after_target_state="HASH $(km_sha256_file "$sealed_target")" ;;
    ABSENT) after_target_state="ABSENT" ;;
    NONE) after_target_state="NONE" ;;
  esac

  {
    echo "version: 1"
    echo "target: ${target}"
    echo "marker: ${marker}"
    echo "before_target: ${before_target_state}"
    echo "before_index: HASH ${before_index_hash}"
    echo "after_target: ${after_target_state}"
    echo "after_index: HASH ${after_index_hash}"
    echo "candidate_id: ${candidate_id}"
    echo "candidate_raw_sha: ${expect_candidate}"
    echo "staged_dir: ${staged_dir}"
    echo "pid: $$"
    echo "timestamp: $(km_now_utc)"
  } > "$store/$jgen/meta"
  chmod 600 "$store/$jgen/meta"

  mv "${store:?}/${jgen:?}" "$store/.journal" || {
    km_error "cannot publish journal"
    rm -rf "${store:?}/${jgen:?}" "${store:?}/${staged_dir:?}"
    return 4
  }
  _km_maybe_die "5"

  # Re-hash sealed copies against AFTER hashes (paranoia check right after publish)
  if [ "$marker" = "HASH" ] && [ "$(km_sha256_file "$sealed_target")" != "${after_target_state#HASH }" ]; then
    _km_run_recovery "$store"
    return 4
  fi
  if [ "$(km_sha256_file "$sealed_index")" != "$after_index_hash" ]; then
    _km_run_recovery "$store"
    return 4
  fi

  # (6) MUTATE target
  case "$marker" in
    HASH) mv "$sealed_target" "$target_path" || { _km_run_recovery "$store"; return 4; } ;;
    ABSENT) rm -f "$target_path" ;;
    NONE) : ;;
  esac
  _km_maybe_die "6"

  # (7) rename sealed MEMORY.md into place
  mv "$sealed_index" "$store/MEMORY.md" || { _km_run_recovery "$store"; return 4; }
  _km_maybe_die "7"

  # (8) VERIFY INSTALLED
  local ok=1
  case "$marker" in
    HASH) [ "$(km_sha256_file "$target_path" 2>/dev/null)" = "${after_target_state#HASH }" ] || ok=0 ;;
    ABSENT) [ ! -e "$target_path" ] || ok=0 ;;
    NONE) : ;;
  esac
  [ "$(km_sha256_file "$store/MEMORY.md" 2>/dev/null)" = "$after_index_hash" ] || ok=0
  if [ "$ok" -ne 1 ]; then
    _km_run_recovery "$store"
    return 4
  fi
  _km_maybe_die "8"

  # (9) delete candidate if named
  if [ "$candidate_id" != "-" ]; then
    _km_consume_candidate "$store" "$candidate_id" "$expect_candidate" || return 4
  fi
  _km_maybe_die "9"

  # (10) delete journal + exact staged generation
  rm -rf "$store/.journal"
  rm -rf "${store:?}/${staged_dir:?}"
  _km_maybe_die "10"

  return 0
}

_km_transaction() {
  local store="$1"
  shift
  _km_lock_acquire "$store" || return $?
  _km_maybe_die "1"
  _km_transaction_body "$store" "$@"
  local rc=$?
  _km_lock_release "$store"
  return $rc
}

# ---------------------------------------------------------------------------
# capture: canonical closed-lexical-subset parser + length-delimited hash.
# ---------------------------------------------------------------------------
KM_PROPOSED_SCALAR_KEYS="schema_version name description created updated last_verified review_after status confidence source supersedes migrated"
KM_PROPOSED_LIST_KEYS="tags"
KM_PROPOSED_MAP_KEYS="metadata"
KM_METADATA_SCALAR_KEYS="type"

_km_cap_scalar() {
  local raw="$1" trimmed
  while [ "${raw:0:1}" = " " ]; do raw="${raw:1}"; done
  trimmed="$raw"
  while [ "${trimmed: -1}" = " " ]; do trimmed="${trimmed% }"; done
  raw="$trimmed"

  if [ -z "$raw" ]; then
    printf ''
    return 0
  fi

  case "${raw:0:1}" in
    '&' | '*' | '!' | '|' | '>' | '[' | '{')
      km_error "unsupported YAML construct in scalar value: $raw"
      return 2
      ;;
  esac

  if [ "${raw:0:1}" = '"' ]; then
    if [ "${#raw}" -lt 2 ] || [ "${raw: -1}" != '"' ]; then
      km_error "unterminated double-quoted scalar: $raw"
      return 2
    fi
    local inner="${raw:1:$((${#raw} - 2))}"
    inner="${inner//\\\\/$'\x1b'}"
    inner="${inner//\\\"/\"}"
    inner="${inner//$'\x1b'/\\}"
    printf '%s' "$inner"
    return 0
  fi

  case "$raw" in
    *\"*)
      km_error "unexpected quote in unquoted scalar: $raw"
      return 2
      ;;
  esac
  printf '%s' "$raw"
}

# km_parse_capture <file> [staged|stored]
# Populates: KM_CAP_SOURCE, KM_CAP_SENSITIVITY, KM_CAP_BODY, KM_CAP_ID,
# KM_CAP_CREATED, KM_CAP_FM_LINES[], KM_CAP_PROPOSED_NAMES/TYPES/VALUES[].
km_parse_capture() {
  local file="$1" mode="${2:-staged}"
  KM_CAP_SOURCE="" KM_CAP_SENSITIVITY="" KM_CAP_BODY="" KM_CAP_ID="" KM_CAP_CREATED=""
  KM_CAP_PROPOSED_NAMES=() KM_CAP_PROPOSED_TYPES=() KM_CAP_PROPOSED_VALUES=()
  KM_CAP_FM_LINES=()

  if [ ! -f "$file" ] || [ -L "$file" ]; then
    km_error "staged file is not a regular file: $file"
    return 2
  fi

  local lineno=0 closed=0 line body_start=0
  local -a fm_lines=()
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ "$lineno" -eq 1 ]; then
      if [ "$line" != "---" ]; then
        km_error "staged file must start with a YAML frontmatter fence: $file"
        return 2
      fi
      continue
    fi
    if [ "$closed" -eq 0 ] && [ "$line" = "---" ]; then
      closed=1
      body_start=$((lineno + 1))
      continue
    fi
    if [ "$closed" -eq 0 ]; then
      case "$line" in
        *$'\t'*)
          km_error "tab characters are not permitted in frontmatter: $file"
          return 2
          ;;
      esac
      fm_lines+=("$line")
    fi
  done < "$file"

  if [ "$closed" -eq 0 ]; then
    km_error "staged file frontmatter fence is not closed: $file"
    return 2
  fi
  if [ "${#fm_lines[@]}" -gt 0 ]; then
    KM_CAP_FM_LINES=("${fm_lines[@]}")
  fi
  if [ "$body_start" -gt 0 ]; then
    KM_CAP_BODY=$(tail -n "+${body_start}" "$file")
  fi

  local seen_source=0 seen_sensitivity=0 seen_proposed=0 seen_id=0 seen_created=0
  local cur_l1_key="" cur_l1_type=""
  local -a seen_l1_keys=()
  local -a list_items=()
  local -a metadata_keys=() metadata_vals=()

  _flush_l1() {
    if [ -n "$cur_l1_key" ]; then
      if [ "$cur_l1_type" = "list" ]; then
        local joined="" first=1 it
        if [ "${#list_items[@]}" -gt 0 ]; then
          for it in "${list_items[@]}"; do
            if [ "$first" -eq 1 ]; then
              joined="$it"
              first=0
            else
              joined="${joined}"$'\x1f'"${it}"
            fi
          done
        fi
        KM_CAP_PROPOSED_NAMES+=("proposed.$cur_l1_key")
        KM_CAP_PROPOSED_TYPES+=("list")
        KM_CAP_PROPOSED_VALUES+=("$joined")
      elif [ "$cur_l1_type" = "metadata" ]; then
        local mi
        for ((mi = 0; mi < ${#metadata_keys[@]}; mi++)); do
          KM_CAP_PROPOSED_NAMES+=("proposed.metadata.${metadata_keys[mi]}")
          KM_CAP_PROPOSED_TYPES+=("scalar")
          KM_CAP_PROPOSED_VALUES+=("${metadata_vals[mi]}")
        done
      fi
    fi
    cur_l1_key=""
    cur_l1_type=""
    list_items=()
    metadata_keys=()
    metadata_vals=()
  }

  local raw indent rest content top_key top_val fmi
  for ((fmi = 0; fmi < ${#fm_lines[@]}; fmi++)); do
    raw="${fm_lines[fmi]}"
    rest="$raw"
    indent=0
    while [ "${rest:0:1}" = " " ]; do
      indent=$((indent + 1))
      rest="${rest:1}"
    done
    content="$rest"

    if [ -z "$content" ]; then
      km_error "blank lines are not permitted inside staged frontmatter: $file"
      return 2
    fi

    case "$indent" in
      0)
        _flush_l1
        case "$content" in
          *:*) : ;;
          *)
            km_error "malformed frontmatter line (expected key:): $content"
            return 2
            ;;
        esac
        top_key="${content%%:*}"
        top_val="${content#*:}"
        while [ "${top_val:0:1}" = " " ]; do top_val="${top_val:1}"; done
        case "$top_key" in
          source)
            [ "$seen_source" -eq 0 ] || { km_error "duplicate key: source"; return 2; }
            seen_source=1
            KM_CAP_SOURCE=$(_km_cap_scalar "$top_val") || return 2
            [ -n "$KM_CAP_SOURCE" ] || { km_error "source must be non-empty"; return 2; }
            ;;
          sensitivity)
            [ "$seen_sensitivity" -eq 0 ] || { km_error "duplicate key: sensitivity"; return 2; }
            seen_sensitivity=1
            KM_CAP_SENSITIVITY=$(_km_cap_scalar "$top_val") || return 2
            case "$KM_CAP_SENSITIVITY" in
              normal | sensitive) : ;;
              *) km_error "sensitivity must be normal or sensitive"; return 2 ;;
            esac
            ;;
          proposed)
            [ "$seen_proposed" -eq 0 ] || { km_error "duplicate key: proposed"; return 2; }
            seen_proposed=1
            [ -z "$top_val" ] || { km_error "proposed: must introduce a mapping (no inline value)"; return 2; }
            ;;
          capture_id)
            if [ "$mode" != "stored" ]; then
              km_error "staged file may not contain capture_id (writer-assigned)"
              return 2
            fi
            [ "$seen_id" -eq 0 ] || { km_error "duplicate key: capture_id"; return 2; }
            seen_id=1
            # shellcheck disable=SC2034  # documented out-param for callers (e.g. future consumers)
            KM_CAP_ID=$(_km_cap_scalar "$top_val") || return 2
            ;;
          created)
            if [ "$mode" != "stored" ]; then
              km_error "staged file may not contain created (writer-assigned)"
              return 2
            fi
            [ "$seen_created" -eq 0 ] || { km_error "duplicate key: created"; return 2; }
            seen_created=1
            # shellcheck disable=SC2034  # documented out-param for callers (e.g. future consumers)
            KM_CAP_CREATED=$(_km_cap_scalar "$top_val") || return 2
            ;;
          *)
            km_error "unknown top-level field: $top_key"
            return 2
            ;;
        esac
        ;;
      2)
        _flush_l1
        case "$content" in
          *:*) : ;;
          *)
            km_error "malformed proposed-field line (expected key:): $content"
            return 2
            ;;
        esac
        local l1_key l1_val
        l1_key="${content%%:*}"
        l1_val="${content#*:}"
        while [ "${l1_val:0:1}" = " " ]; do l1_val="${l1_val:1}"; done
        if _km_in_list "$l1_key" "${seen_l1_keys[*]:-}"; then
          km_error "duplicate proposed field: $l1_key"
          return 2
        fi
        seen_l1_keys+=("$l1_key")
        if [ -n "$l1_val" ]; then
          if _km_in_list "$l1_key" "$KM_PROPOSED_SCALAR_KEYS"; then
            local sv
            sv=$(_km_cap_scalar "$l1_val") || return 2
            KM_CAP_PROPOSED_NAMES+=("proposed.$l1_key")
            KM_CAP_PROPOSED_TYPES+=("scalar")
            KM_CAP_PROPOSED_VALUES+=("$sv")
          else
            km_error "unknown or non-scalar proposed field: $l1_key"
            return 2
          fi
        else
          if _km_in_list "$l1_key" "$KM_PROPOSED_LIST_KEYS"; then
            cur_l1_key="$l1_key"
            cur_l1_type="list"
          elif _km_in_list "$l1_key" "$KM_PROPOSED_MAP_KEYS"; then
            cur_l1_key="$l1_key"
            cur_l1_type="metadata"
          else
            km_error "unknown proposed field or unsupported empty value: $l1_key"
            return 2
          fi
        fi
        ;;
      4)
        if [ -z "$cur_l1_key" ]; then
          km_error "unexpected indentation: $raw"
          return 2
        fi
        case "$content" in
          "- "*)
            if [ "$cur_l1_type" != "list" ]; then
              km_error "unexpected list item under non-list field: $cur_l1_key"
              return 2
            fi
            local item_raw item
            item_raw="${content#- }"
            item=$(_km_cap_scalar "$item_raw") || return 2
            list_items+=("$item")
            ;;
          *:*)
            if [ "$cur_l1_type" != "metadata" ]; then
              km_error "nested mappings are only permitted under metadata: $cur_l1_key"
              return 2
            fi
            local mkey mval mv
            mkey="${content%%:*}"
            mval="${content#*:}"
            while [ "${mval:0:1}" = " " ]; do mval="${mval:1}"; done
            if ! _km_in_list "$mkey" "$KM_METADATA_SCALAR_KEYS"; then
              km_error "unknown metadata field: $mkey"
              return 2
            fi
            if _km_in_list "$mkey" "${metadata_keys[*]:-}"; then
              km_error "duplicate metadata field: $mkey"
              return 2
            fi
            metadata_keys+=("$mkey")
            mv=$(_km_cap_scalar "$mval") || return 2
            metadata_vals+=("$mv")
            ;;
          *)
            km_error "malformed line under $cur_l1_key: $content"
            return 2
            ;;
        esac
        ;;
      *)
        km_error "invalid indentation ($indent spaces): $raw"
        return 2
        ;;
    esac
  done
  _flush_l1

  if [ "$seen_source" -ne 1 ] || [ "$seen_sensitivity" -ne 1 ] || [ "$seen_proposed" -ne 1 ]; then
    km_error "staged file must contain exactly source, sensitivity, and proposed"
    return 2
  fi
  if [ "$mode" = "stored" ] && { [ "$seen_id" -ne 1 ] || [ "$seen_created" -ne 1 ]; }; then
    km_error "stored candidate must contain capture_id and created"
    return 2
  fi
  return 0
}

_km_emit_field() {
  local out="$1" name="$2" value="$3" len
  printf '%s\n' "$name" >> "$out"
  len=$(printf '%s' "$value" | wc -c | tr -d ' ')
  printf '%s\n' "$len" >> "$out"
  printf '%s' "$value" >> "$out"
  printf '\n' >> "$out"
}

km_normalize_capture_body() {
  printf '%s' "$1" | awk '
    { sub(/\r$/, ""); sub(/[ \t]+$/, ""); lines[NR] = $0 }
    END {
      n = NR
      start = 1; while (start <= n && lines[start] == "") start++
      stop = n; while (stop >= start && lines[stop] == "") stop--
      out = ""
      for (i = start; i <= stop; i++) {
        if (i > start) out = out "\n"
        out = out lines[i]
      }
      printf "%s", out
    }
  '
}

# Requires KM_CAP_* globals already populated by km_parse_capture.
km_capture_canonical_hash() {
  local tmp sortfile hash
  tmp=$(mktemp) || return 1
  sortfile=$(mktemp) || { rm -f "$tmp"; return 1; }

  _km_emit_field "$tmp" "source" "$KM_CAP_SOURCE"
  _km_emit_field "$tmp" "sensitivity" "$KM_CAP_SENSITIVITY"

  local i
  : > "$sortfile"
  for ((i = 0; i < ${#KM_CAP_PROPOSED_NAMES[@]}; i++)); do
    printf '%s\t%d\n' "${KM_CAP_PROPOSED_NAMES[i]}" "$i" >> "$sortfile"
  done

  local nm idx val joined first item
  while IFS=$'\t' read -r nm idx; do
    [ -n "$nm" ] || continue
    if [ "${KM_CAP_PROPOSED_TYPES[idx]}" = "list" ]; then
      val="${KM_CAP_PROPOSED_VALUES[idx]}"
      joined="" first=1
      if [ -n "$val" ]; then
        local -a items=()
        IFS=$'\x1f' read -r -a items <<< "$val"
        local ii
        for ((ii = 0; ii < ${#items[@]}; ii++)); do
          item="${items[ii]}"
          if [ "$first" -eq 1 ]; then
            joined="$item"
            first=0
          else
            joined="${joined}"$'\n'"${item}"
          fi
        done
      fi
      _km_emit_field "$tmp" "$nm" "$joined"
    else
      _km_emit_field "$tmp" "$nm" "${KM_CAP_PROPOSED_VALUES[idx]}"
    fi
  done < <(LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$sortfile")

  local norm_body
  norm_body=$(km_normalize_capture_body "$KM_CAP_BODY")
  _km_emit_field "$tmp" "body" "$norm_body"

  hash=$(km_sha256_file "$tmp")
  rm -f "$tmp" "$sortfile"
  printf '%s\n' "$hash"
}

_km_ensure_inbox_dir() {
  local store="$1" owner mode
  local dir="$store/.inbox"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    if [ -L "$dir" ] || [ ! -d "$dir" ]; then
      km_error ".inbox exists but is not a safe directory: $dir"
      return 4
    fi
    owner=$(km_path_uid "$dir") || return 4
    [ "$owner" = "$(id -u)" ] || { km_error ".inbox has a foreign owner: $dir"; return 4; }
    mode=$(km_path_mode "$dir") || return 4
    [ "$mode" = "700" ] || { km_error ".inbox must be mode 700 (found $mode): $dir"; return 4; }
    return 0
  fi
  ( umask 077; mkdir -m 700 "$dir" ) || { km_error "cannot create .inbox: $dir"; return 4; }
  return 0
}

_km_capture_body() {
  local store="$1" staged_file="$2" key="$3"
  local target="$store/.inbox/${key}.md" existing_hash new_hash ts tmp l
  _km_ensure_inbox_dir "$store" || return 4

  if km_path_exists "$target"; then
    if [ -L "$target" ] || [ ! -f "$target" ]; then
      km_error "candidate path is not a safe regular file: $target"
      return 4
    fi
    km_parse_capture "$target" stored || { km_error "existing candidate is unparseable: $target"; return 4; }
    existing_hash=$(km_capture_canonical_hash) || return 4
    km_parse_capture "$staged_file" staged || return 2
    new_hash=$(km_capture_canonical_hash) || return 2
    if [ "$existing_hash" = "$new_hash" ]; then
      echo "capture_id: ${key}"
      echo "status: no-op (existing candidate unchanged)"
      return 0
    fi
    km_error "candidate ${key} already exists with different content (store-integrity)"
    return 4
  fi

  km_parse_capture "$staged_file" staged || return 2
  ts=$(km_now_utc)
  tmp=$(mktemp "$store/.inbox/.capture.tmp.XXXXXX") || { km_error "cannot create capture temp file"; return 4; }
  {
    echo "---"
    echo "capture_id: $key"
    echo "created: $ts"
    if [ "${#KM_CAP_FM_LINES[@]}" -gt 0 ]; then
      for l in "${KM_CAP_FM_LINES[@]}"; do printf '%s\n' "$l"; done
    fi
    echo "---"
    printf '%s\n' "$KM_CAP_BODY"
  } > "$tmp"
  chmod 600 "$tmp"
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    km_error "cannot publish candidate: $target"
    return 4
  fi
  echo "capture_id: $key"
  echo "created: $ts"
  return 0
}

# ---------------------------------------------------------------------------
# purge helpers
# ---------------------------------------------------------------------------
_km_iso_to_epoch() {
  local iso="$1"
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null ||
    date -u -d "$iso" +%s 2>/dev/null
}

_km_candidate_created() {
  local f="$1" line
  line=$(grep -m1 '^created: ' "$f" 2>/dev/null) || { echo ""; return 0; }
  printf '%s\n' "${line#created: }"
}

_km_candidate_verdict() {
  local created="$1" retention_days="$2" created_epoch now_epoch age_days
  if [ -z "$created" ]; then
    echo "active"
    return 0
  fi
  created_epoch=$(_km_iso_to_epoch "$created") || { echo "active"; return 0; }
  now_epoch=$(date -u +%s)
  age_days=$(((now_epoch - created_epoch) / 86400))
  if [ "$age_days" -ge "$retention_days" ]; then
    echo "expired"
  else
    echo "active"
  fi
}

_km_inbox_select() {
  local store="$1" have_ids="$2" ids_csv="$3" retention_days="$4"
  local f cid created verdict
  if [ "$have_ids" -eq 1 ]; then
    local -a idarr=()
    IFS=',' read -r -a idarr <<< "$ids_csv"
    local id idi
    for ((idi = 0; idi < ${#idarr[@]}; idi++)); do
      id="${idarr[idi]}"
      [ -n "$id" ] && printf '%s\n' "$id"
    done | LC_ALL=C sort -u
  else
    if [ -d "$store/.inbox" ]; then
      find "$store/.inbox" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null | while IFS= read -r f; do
        [ -L "$f" ] && continue
        cid=$(basename "$f" .md)
        created=$(_km_candidate_created "$f")
        verdict=$(_km_candidate_verdict "$created" "$retention_days")
        [ "$verdict" = "expired" ] && printf '%s\n' "$cid"
      done | LC_ALL=C sort
    fi
  fi
}

_km_purge_plan() {
  local store="$1" have_ids="$2" ids="$3" retention_days="$4"
  local cid cfile created raw verdict
  local -a lines=()
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    cfile="$store/.inbox/${cid}.md"
    if [ ! -f "$cfile" ] || [ -L "$cfile" ]; then
      continue
    fi
    created=$(_km_candidate_created "$cfile")
    raw=$(km_sha256_file "$cfile")
    verdict=$(_km_candidate_verdict "$created" "$retention_days")
    lines+=("$cid $raw $created $verdict")
  done < <(_km_inbox_select "$store" "$have_ids" "$ids" "$retention_days")
  if [ "${#lines[@]}" -gt 0 ]; then
    printf '%s\n' "${lines[@]}" | LC_ALL=C sort
  fi
}

_km_purge_apply() {
  local store="$1" have_ids="$2" retention_days="$3" manifest="$4"
  local line
  local -a mlines=()
  if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
    km_error "manifest is not a regular file: $manifest"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || { km_error "manifest contains a blank line"; return 2; }
    mlines+=("$line")
  done < "$manifest"
  if [ "${#mlines[@]}" -eq 0 ]; then
    km_error "manifest is empty"
    return 2
  fi

  local id raw created verdict
  local -a seen_ids=()
  for line in "${mlines[@]}"; do
    set -- $line
    if [ "$#" -ne 4 ]; then
      km_error "malformed manifest line: $line"
      return 2
    fi
    id="$1"; raw="$2"; created="$3"; verdict="$4"
    case "$verdict" in
      expired | active) : ;;
      *) km_error "invalid verdict vocabulary: $verdict"; return 2 ;;
    esac
    if _km_in_list "$id" "${seen_ids[*]:-}"; then
      km_error "duplicate id in manifest: $id"
      return 2
    fi
    seen_ids+=("$id")
  done

  _km_lock_acquire "$store" || return $?

  local nonce staged_dir sealed_manifest rc=0
  nonce=$(km_random_hex32) || { _km_lock_release "$store"; km_error "cannot generate nonce"; return 4; }
  staged_dir=".staged.$$.${nonce}"
  if ! ( umask 077; mkdir -m 700 "${store:?}/${staged_dir:?}" ); then
    km_error "cannot seal manifest"
    _km_lock_release "$store"
    return 4
  fi
  sealed_manifest="$store/$staged_dir/manifest"
  if ! cp "$manifest" "$sealed_manifest" || ! chmod 600 "$sealed_manifest" 2>/dev/null; then
    km_error "cannot seal manifest"
    rm -rf "${store:?}/${staged_dir:?}"
    _km_lock_release "$store"
    return 4
  fi

  local cfile live_raw live_created recomputed
  for line in "${mlines[@]}"; do
    set -- $line
    id="$1"; raw="$2"; created="$3"
    cfile="$store/.inbox/${id}.md"
    if [ ! -f "$cfile" ] || [ -L "$cfile" ]; then
      km_error "manifest candidate not found or unsafe: $id"
      rm -rf "${store:?}/${staged_dir:?}"
      _km_lock_release "$store"
      return 4
    fi
    live_raw=$(km_sha256_file "$cfile")
    live_created=$(_km_candidate_created "$cfile")
    if [ "$live_raw" != "$raw" ] || [ "$live_created" != "$created" ]; then
      km_error "manifest CAS mismatch for candidate: $id"
      rm -rf "${store:?}/${staged_dir:?}"
      _km_lock_release "$store"
      return 4
    fi
    if [ "$have_ids" -eq 0 ]; then
      recomputed=$(_km_candidate_verdict "$live_created" "$retention_days")
      if [ "$recomputed" != "expired" ]; then
        km_error "candidate no longer expired; re-plan: $id"
        rm -rf "${store:?}/${staged_dir:?}"
        _km_lock_release "$store"
        return 4
      fi
    fi
  done

  for line in "${mlines[@]}"; do
    set -- $line
    id="$1"; raw="$2"
    cfile="$store/.inbox/${id}.md"
    if [ ! -f "$cfile" ] || [ -L "$cfile" ]; then
      km_error "candidate vanished or became unsafe mid-purge: $id"
      rc=4
      break
    fi
    live_raw=$(km_sha256_file "$cfile")
    if [ "$live_raw" != "$raw" ]; then
      km_error "candidate changed mid-purge (filename/content mismatch): $id"
      rc=4
      break
    fi
    rm -f "$cfile"
    echo "purged: $id"
    if [ -n "${KNOWLEDGE_TEST_DIE_AFTER_PURGE_ID:-}" ] && [ "${KNOWLEDGE_TEST_DIE_AFTER_PURGE_ID}" = "$id" ]; then
      exit 137
    fi
  done

  rm -rf "${store:?}/${staged_dir:?}"
  _km_lock_release "$store"
  return "$rc"
}

# ---------------------------------------------------------------------------
# bootstrap
# ---------------------------------------------------------------------------
_km_create_ancestor_component() {
  local parent="$1" name="$2" owner
  local path="$parent/$name"
  if [ -L "$parent" ] || [ ! -d "$parent" ]; then
    km_error "unsafe ancestor while creating memory store: $parent"
    return 4
  fi
  owner=$(km_path_uid "$parent") || return 4
  [ "$owner" = "$(id -u)" ] || { km_error "ancestor has a foreign owner: $parent"; return 4; }
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ -L "$path" ] || [ ! -d "$path" ]; then
      km_error "unsafe existing ancestor component: $path"
      return 4
    fi
    owner=$(km_path_uid "$path") || return 4
    [ "$owner" = "$(id -u)" ] || { km_error "ancestor component has a foreign owner: $path"; return 4; }
    return 0
  fi
  ( umask 077; mkdir -m 700 "$path" ) || { km_error "cannot create ancestor: $path"; return 4; }
  return 0
}

cmd_bootstrap() {
  local store_arg="" seen_store=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --store)
        [ $# -ge 2 ] || { km_error "--store requires a value"; return 2; }
        [ "$seen_store" -eq 0 ] || { km_error "--store may not be repeated"; return 2; }
        seen_store=1
        store_arg="$2"
        shift 2
        ;;
      *)
        km_error "bootstrap: unknown argument: $1"
        return 2
        ;;
    esac
  done
  [ -n "$store_arg" ] || { km_error "Usage: memory-write.sh bootstrap --store <path>"; return 2; }

  km_require_non_reviewer "memory" || return 6

  local target="$store_arg" parent
  parent=$(dirname "$target")

  if [ -e "$target" ] || [ -L "$target" ]; then
    if km_validate_store_dir "$target" >/dev/null 2>&1; then
      echo "already initialized: $target"
      return 0
    fi
    km_error "target exists but is not a healthy store: $target"
    return 4
  fi

  if ! km_verify_gitignored "$target"; then
    km_error "$target is not covered by .gitignore; apply the init plan's diff first"
    return 3
  fi

  if ! km_git_ancestor "$parent" >/dev/null 2>&1; then
    km_error "bootstrap target is not inside a git repository: $target"
    return 3
  fi

  local repo_root canonical_default=0
  repo_root=$(km_git_ancestor "$parent")
  if [ "$target" = "$repo_root/.agents/memory" ]; then
    canonical_default=1
  fi

  if [ "$canonical_default" -eq 1 ]; then
    # Component-by-component beneath the existing owned repo root: .agents/
    # then memory/ (the store dir itself is the last "component" — no
    # separate mkdir follows).
    _km_create_ancestor_component "$repo_root" ".agents" || return 4
    _km_create_ancestor_component "$repo_root/.agents" "memory" || return 4
  else
    if [ -L "$parent" ] || [ ! -d "$parent" ]; then
      km_error "bootstrap parent must already exist as a real directory: $parent"
      return 4
    fi
    local powner
    powner=$(km_path_uid "$parent") || return 4
    [ "$powner" = "$(id -u)" ] || { km_error "bootstrap parent has a foreign owner: $parent"; return 4; }
    if ! ( umask 077; mkdir -m 700 "$target" ); then
      km_error "cannot create memory store directory (or raced with a concurrent creation): $target"
      return 4
    fi
  fi

  if ! ( umask 077; : > "$target/MEMORY.md" ) || ! chmod 600 "$target/MEMORY.md"; then
    km_error "cannot create MEMORY.md: $target/MEMORY.md"
    return 4
  fi
  echo "created: $target"
  return 0
}

# ---------------------------------------------------------------------------
# capture
# ---------------------------------------------------------------------------
cmd_capture() {
  local store_arg="" staged_file="" idemp_key=""
  local seen_store=0 seen_staged=0 seen_key=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --store)
        [ $# -ge 2 ] || { km_error "--store requires a value"; return 2; }
        [ "$seen_store" -eq 0 ] || { km_error "--store may not be repeated"; return 2; }
        seen_store=1; store_arg="$2"; shift 2 ;;
      --staged)
        [ $# -ge 2 ] || { km_error "--staged requires a value"; return 2; }
        [ "$seen_staged" -eq 0 ] || { km_error "--staged may not be repeated"; return 2; }
        seen_staged=1; staged_file="$2"; shift 2 ;;
      --idempotency-key)
        [ $# -ge 2 ] || { km_error "--idempotency-key requires a value"; return 2; }
        [ "$seen_key" -eq 0 ] || { km_error "--idempotency-key may not be repeated"; return 2; }
        seen_key=1; idemp_key="$2"; shift 2 ;;
      *)
        km_error "capture: unknown argument: $1"
        return 2
        ;;
    esac
  done
  if [ -z "$store_arg" ] || [ -z "$staged_file" ] || [ -z "$idemp_key" ]; then
    km_error "Usage: memory-write.sh capture --store <path> --staged <file> --idempotency-key <sha256>"
    return 2
  fi
  if ! [[ "$idemp_key" =~ ^[0-9a-f]{64}$ ]]; then
    km_error "idempotency-key must be a 64-char lowercase hex sha256"
    return 2
  fi

  km_require_non_reviewer "memory" || return 6

  local store
  store=$(km_resolve_store "$store_arg") || return $?

  km_parse_capture "$staged_file" staged || return 2
  local computed_hash
  computed_hash=$(km_capture_canonical_hash) || return 2
  if [ "$computed_hash" != "$idemp_key" ]; then
    km_error "idempotency-key does not match recomputed canonical encoding"
    return 2
  fi

  if ! km_verify_gitignored "$store"; then
    km_error "memory store is not covered by .gitignore: $store"
    return 4
  fi

  _km_lock_acquire "$store" || return $?
  _km_capture_body "$store" "$staged_file" "$idemp_key"
  local rc=$?
  _km_lock_release "$store"
  return $rc
}

# ---------------------------------------------------------------------------
# apply / index / retire
# ---------------------------------------------------------------------------
cmd_apply() {
  local store_arg="" target="" staged_target="" staged_index=""
  local expect_target="" expect_index="" candidate_id="-" expect_candidate="-" have_candidate=0
  local seen_store=0 seen_target=0 seen_staged_target=0 seen_staged_index=0
  local seen_expect_target=0 seen_expect_index=0 seen_expect_candidate=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --store)
        [ $# -ge 2 ] || { km_error "--store requires a value"; return 2; }
        [ "$seen_store" -eq 0 ] || { km_error "--store may not be repeated"; return 2; }
        seen_store=1; store_arg="$2"; shift 2 ;;
      --target)
        [ $# -ge 2 ] || { km_error "--target requires a value"; return 2; }
        [ "$seen_target" -eq 0 ] || { km_error "--target may not be repeated"; return 2; }
        seen_target=1; target="$2"; shift 2 ;;
      --staged-target)
        [ $# -ge 2 ] || { km_error "--staged-target requires a value"; return 2; }
        [ "$seen_staged_target" -eq 0 ] || { km_error "--staged-target may not be repeated"; return 2; }
        seen_staged_target=1; staged_target="$2"; shift 2 ;;
      --staged-index)
        [ $# -ge 2 ] || { km_error "--staged-index requires a value"; return 2; }
        [ "$seen_staged_index" -eq 0 ] || { km_error "--staged-index may not be repeated"; return 2; }
        seen_staged_index=1; staged_index="$2"; shift 2 ;;
      --expect-target)
        [ $# -ge 2 ] || { km_error "--expect-target requires a value"; return 2; }
        [ "$seen_expect_target" -eq 0 ] || { km_error "--expect-target may not be repeated"; return 2; }
        seen_expect_target=1; expect_target="$2"; shift 2 ;;
      --expect-index)
        [ $# -ge 2 ] || { km_error "--expect-index requires a value"; return 2; }
        [ "$seen_expect_index" -eq 0 ] || { km_error "--expect-index may not be repeated"; return 2; }
        seen_expect_index=1; expect_index="$2"; shift 2 ;;
      --candidate)
        [ $# -ge 2 ] || { km_error "--candidate requires a value"; return 2; }
        [ "$have_candidate" -eq 0 ] || { km_error "--candidate may not be repeated"; return 2; }
        have_candidate=1; candidate_id="$2"; shift 2 ;;
      --expect-candidate)
        [ $# -ge 2 ] || { km_error "--expect-candidate requires a value"; return 2; }
        [ "$seen_expect_candidate" -eq 0 ] || { km_error "--expect-candidate may not be repeated"; return 2; }
        seen_expect_candidate=1; expect_candidate="$2"; shift 2 ;;
      *) km_error "apply: unknown argument: $1"; return 2 ;;
    esac
  done
  if [ -z "$store_arg" ] || [ -z "$target" ] || [ -z "$staged_target" ] || [ -z "$staged_index" ] \
    || [ -z "$expect_target" ] || [ -z "$expect_index" ]; then
    km_error "Usage: memory-write.sh apply --store <path> --target <basename>.md --staged-target <file> --staged-index <file> --expect-target <sha256|absent> --expect-index <sha256> [--candidate <id> --expect-candidate <sha256>]"
    return 2
  fi
  if [ "$have_candidate" -eq 1 ] && [ "$expect_candidate" = "-" ]; then
    km_error "--candidate requires --expect-candidate"
    return 2
  fi
  if [ "$have_candidate" -eq 0 ] && [ "$expect_candidate" != "-" ]; then
    km_error "--expect-candidate requires --candidate"
    return 2
  fi
  case "$target" in
    MEMORY.md) km_error "--target may not be MEMORY.md (reserved)"; return 2 ;;
    .*) km_error "--target may not be dot-prefixed (reserved)"; return 2 ;;
  esac
  case "$target" in
    */*) km_error "--target must be a bare basename"; return 2 ;;
    *.md) : ;;
    *) km_error "--target must end in .md"; return 2 ;;
  esac

  km_require_non_reviewer "memory" || return 6
  local store
  store=$(km_resolve_store "$store_arg") || return $?
  km_slug_collision_check "$store" || return 4

  local stem="${target%.md}" exists_exact=0 f
  while IFS= read -r f; do
    [ "$f" = "$target" ] && exists_exact=1
  done < <(km_authoritative_files "$store")
  if [ "$exists_exact" -ne 1 ] && ! km_is_valid_slug "$stem"; then
    km_error "--target must match the canonical slug regex or name an existing authoritative file: $target"
    return 2
  fi

  _km_transaction "$store" "$target" HASH "$staged_target" "$staged_index" \
    "$expect_target" "$expect_index" "$candidate_id" "$expect_candidate"
}

cmd_index() {
  local store_arg="" staged_index="" expect_index=""
  local seen_store=0 seen_staged_index=0 seen_expect_index=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --store)
        [ $# -ge 2 ] || { km_error "--store requires a value"; return 2; }
        [ "$seen_store" -eq 0 ] || { km_error "--store may not be repeated"; return 2; }
        seen_store=1; store_arg="$2"; shift 2 ;;
      --staged-index)
        [ $# -ge 2 ] || { km_error "--staged-index requires a value"; return 2; }
        [ "$seen_staged_index" -eq 0 ] || { km_error "--staged-index may not be repeated"; return 2; }
        seen_staged_index=1; staged_index="$2"; shift 2 ;;
      --expect-index)
        [ $# -ge 2 ] || { km_error "--expect-index requires a value"; return 2; }
        [ "$seen_expect_index" -eq 0 ] || { km_error "--expect-index may not be repeated"; return 2; }
        seen_expect_index=1; expect_index="$2"; shift 2 ;;
      *) km_error "index: unknown argument: $1"; return 2 ;;
    esac
  done
  if [ -z "$store_arg" ] || [ -z "$staged_index" ] || [ -z "$expect_index" ]; then
    km_error "Usage: memory-write.sh index --store <path> --staged-index <file> --expect-index <sha256>"
    return 2
  fi

  km_require_non_reviewer "memory" || return 6
  local store
  store=$(km_resolve_store "$store_arg") || return $?

  _km_transaction "$store" "NONE" NONE "" "$staged_index" "" "$expect_index" "-" "-"
}

cmd_retire() {
  local store_arg="" slug="" staged_index="" expect_target="" expect_index="" confirm=""
  local seen_store=0 seen_slug=0 seen_staged_index=0 seen_expect_target=0 seen_expect_index=0 seen_confirm=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --store)
        [ $# -ge 2 ] || { km_error "--store requires a value"; return 2; }
        [ "$seen_store" -eq 0 ] || { km_error "--store may not be repeated"; return 2; }
        seen_store=1; store_arg="$2"; shift 2 ;;
      --slug)
        [ $# -ge 2 ] || { km_error "--slug requires a value"; return 2; }
        [ "$seen_slug" -eq 0 ] || { km_error "--slug may not be repeated"; return 2; }
        seen_slug=1; slug="$2"; shift 2 ;;
      --staged-index)
        [ $# -ge 2 ] || { km_error "--staged-index requires a value"; return 2; }
        [ "$seen_staged_index" -eq 0 ] || { km_error "--staged-index may not be repeated"; return 2; }
        seen_staged_index=1; staged_index="$2"; shift 2 ;;
      --expect-target)
        [ $# -ge 2 ] || { km_error "--expect-target requires a value"; return 2; }
        [ "$seen_expect_target" -eq 0 ] || { km_error "--expect-target may not be repeated"; return 2; }
        seen_expect_target=1; expect_target="$2"; shift 2 ;;
      --expect-index)
        [ $# -ge 2 ] || { km_error "--expect-index requires a value"; return 2; }
        [ "$seen_expect_index" -eq 0 ] || { km_error "--expect-index may not be repeated"; return 2; }
        seen_expect_index=1; expect_index="$2"; shift 2 ;;
      --confirm)
        [ $# -ge 2 ] || { km_error "--confirm requires a value"; return 2; }
        [ "$seen_confirm" -eq 0 ] || { km_error "--confirm may not be repeated"; return 2; }
        seen_confirm=1; confirm="$2"; shift 2 ;;
      *) km_error "retire: unknown argument: $1"; return 2 ;;
    esac
  done
  if [ -z "$store_arg" ] || [ -z "$slug" ] || [ -z "$staged_index" ] || [ -z "$expect_target" ] \
    || [ -z "$expect_index" ] || [ -z "$confirm" ]; then
    km_error "Usage: memory-write.sh retire --store <path> --slug <slug> --staged-index <file> --expect-target <sha256> --expect-index <sha256> --confirm <path>"
    return 2
  fi
  if [ "$confirm" != "$store_arg" ]; then
    km_error "--confirm must byte-equal --store"
    return 2
  fi

  # Containment (argv-only, no store dependency, checked before role/store
  # guards): --slug must be a single safe bare component. retire resolves by
  # EXACT STEM ONLY (spec), so it never needs and never accepts "/", ".", or
  # ".." — accepting any of those let a crafted --slug walk `$store/<slug>.md`
  # outside the store (CVE-class path traversal; a prior version of this
  # script was vulnerable here). Reserved names mirror apply's --target
  # reserved set (translated to the no-".md" slug shape): the index stem and
  # dot-prefixed names.
  if ! _km_is_safe_bare_component "$slug"; then
    km_error "--slug must be a single safe path component (no /, \\, ., or ..): $slug"
    return 2
  fi
  case "$slug" in
    .*) km_error "--slug may not be dot-prefixed (reserved)"; return 2 ;;
    MEMORY) km_error "--slug may not be MEMORY (reserved index stem)"; return 2 ;;
  esac

  km_require_non_reviewer "memory" || return 6
  local store
  store=$(km_resolve_store "$store_arg") || return $?
  km_slug_collision_check "$store" || return 4

  # Existence/authoritative-set membership can only be checked once the
  # store is resolved. A symlink sitting at the target path is a store-
  # integrity condition (exit 4, matching the scanner-boundary treatment
  # elsewhere); anything else that fails to resolve by exact stem is an
  # ordinary bad-argument case (exit 2), same class as apply's --target
  # validity check just below in cmd_apply.
  local target="${slug}.md" target_path
  target_path="$store/$target"
  if [ -L "$target_path" ]; then
    km_error "retire target is a symlink (store-integrity, excluded from the authoritative set): $target_path"
    return 4
  fi
  local exists_exact=0 f
  while IFS= read -r f; do
    [ "$f" = "$target" ] && exists_exact=1
  done < <(km_authoritative_files "$store")
  if [ "$exists_exact" -ne 1 ]; then
    km_error "--slug does not name an existing authoritative file (exact-stem match required): $slug"
    return 2
  fi

  _km_transaction "$store" "$target" ABSENT "" "$staged_index" "$expect_target" "$expect_index" "-" "-"
}

# ---------------------------------------------------------------------------
# purge
# ---------------------------------------------------------------------------
cmd_purge() {
  local store_arg="" ids="" expired=0 manifest="" confirm="" have_ids=0
  local seen_store=0 seen_expired=0 seen_manifest=0 seen_confirm=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --store)
        [ $# -ge 2 ] || { km_error "--store requires a value"; return 2; }
        [ "$seen_store" -eq 0 ] || { km_error "--store may not be repeated"; return 2; }
        seen_store=1; store_arg="$2"; shift 2 ;;
      --ids)
        [ $# -ge 2 ] || { km_error "--ids requires a value"; return 2; }
        [ "$have_ids" -eq 0 ] || { km_error "--ids may not be repeated"; return 2; }
        have_ids=1; ids="$2"; shift 2 ;;
      --expired)
        [ "$seen_expired" -eq 0 ] || { km_error "--expired may not be repeated"; return 2; }
        seen_expired=1; expired=1; shift 1 ;;
      --manifest)
        [ $# -ge 2 ] || { km_error "--manifest requires a value"; return 2; }
        [ "$seen_manifest" -eq 0 ] || { km_error "--manifest may not be repeated"; return 2; }
        seen_manifest=1; manifest="$2"; shift 2 ;;
      --confirm)
        [ $# -ge 2 ] || { km_error "--confirm requires a value"; return 2; }
        [ "$seen_confirm" -eq 0 ] || { km_error "--confirm may not be repeated"; return 2; }
        seen_confirm=1; confirm="$2"; shift 2 ;;
      *) km_error "purge: unknown argument: $1"; return 2 ;;
    esac
  done
  if [ -z "$store_arg" ]; then
    km_error "Usage: memory-write.sh purge --store <path> (--ids <id,...> | --expired) [--manifest <file>] --confirm <path>"
    return 2
  fi
  if [ "$have_ids" -eq 1 ] && [ "$expired" -eq 1 ]; then
    km_error "--ids and --expired are mutually exclusive"
    return 2
  fi
  if [ "$have_ids" -eq 0 ] && [ "$expired" -eq 0 ]; then
    km_error "exactly one of --ids or --expired is required"
    return 2
  fi
  if [ "$have_ids" -eq 1 ] && ! _km_validate_ids_csv "$ids"; then
    km_error "--ids must be a comma-separated list of 64-char lowercase-hex candidate ids: $ids"
    return 2
  fi

  local retention_days="${KNOWLEDGE_INBOX_RETENTION_DAYS:-30}"

  if [ -z "$manifest" ]; then
    km_require_non_reviewer "memory" || return 6
    local store
    store=$(km_resolve_store "$store_arg") || return $?
    _km_purge_plan "$store" "$have_ids" "$ids" "$retention_days"
    return 0
  fi

  if [ -z "$confirm" ]; then
    km_error "--manifest requires --confirm <store-path>"
    return 2
  fi
  if [ "$confirm" != "$store_arg" ]; then
    km_error "--confirm must byte-equal --store"
    return 2
  fi
  km_require_non_reviewer "memory" || return 6
  local store
  store=$(km_resolve_store "$store_arg") || return $?
  _km_purge_apply "$store" "$have_ids" "$retention_days" "$manifest"
}

# ---------------------------------------------------------------------------
# unlock
# ---------------------------------------------------------------------------
_km_report_orphaned_claims() {
  local store="$1" f
  find "$store" -mindepth 1 -maxdepth 1 -name '.lock.claim.*' 2>/dev/null | while IFS= read -r f; do
    echo "orphaned claim file: $f"
  done
}

_km_unlock_body() {
  local store="$1"
  local lock="$store/.lock"
  if [ ! -e "$lock" ]; then
    echo "no lock present: $store"
    _km_report_orphaned_claims "$store"
    return 0
  fi
  if [ -L "$lock" ] || [ ! -f "$lock" ]; then
    km_error ".lock is not a safe regular file: $lock"
    return 4
  fi

  local lock_id holder_claim="" f fid
  lock_id=$(km_path_identity "$lock")
  while IFS= read -r f; do
    fid=$(km_path_identity "$f" 2>/dev/null) || continue
    [ "$fid" = "$lock_id" ] && holder_claim="$f"
  done < <(find "$store" -mindepth 1 -maxdepth 1 -name '.lock.claim.*' 2>/dev/null)

  if [ -z "$holder_claim" ]; then
    km_error "cannot identify the lock's owning claim file (integrity)"
    return 4
  fi

  local holder_pid
  holder_pid=$(grep -m1 '^pid: ' "$holder_claim" 2>/dev/null | sed 's/^pid: //')
  if [ -z "$holder_pid" ]; then
    km_error "lock claim has no readable pid"
    return 4
  fi

  if km_pid_alive "$holder_pid"; then
    echo "lock holder is alive (pid $holder_pid): refusing to unlock" >&2
    cat "$lock" >&2
    return 5
  fi

  echo "dead lock holder (pid $holder_pid); removing:"
  cat "$lock"
  rm -f "$lock" || { km_error "cannot remove .lock"; return 4; }
  rm -f "$holder_claim" || { km_error "cannot remove lock claim"; return 4; }
  echo "unlocked: $store"
  _km_report_orphaned_claims "$store"
  return 0
}

cmd_unlock() {
  local store_arg="" confirm=""
  local seen_store=0 seen_confirm=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --store)
        [ $# -ge 2 ] || { km_error "--store requires a value"; return 2; }
        [ "$seen_store" -eq 0 ] || { km_error "--store may not be repeated"; return 2; }
        seen_store=1; store_arg="$2"; shift 2 ;;
      --confirm)
        [ $# -ge 2 ] || { km_error "--confirm requires a value"; return 2; }
        [ "$seen_confirm" -eq 0 ] || { km_error "--confirm may not be repeated"; return 2; }
        seen_confirm=1; confirm="$2"; shift 2 ;;
      *) km_error "unlock: unknown argument: $1"; return 2 ;;
    esac
  done
  if [ -z "$store_arg" ] || [ -z "$confirm" ]; then
    km_error "Usage: memory-write.sh unlock --store <path> --confirm <path>"
    return 2
  fi
  if [ "$confirm" != "$store_arg" ]; then
    km_error "--confirm must byte-equal --store"
    return 2
  fi

  km_require_non_reviewer "memory" || return 6
  local store
  store=$(km_resolve_store "$store_arg") || return $?

  recovery_mutex "$store" 10 _km_unlock_body "$store"
}

# ---------------------------------------------------------------------------
# dispatch — guarded so the test suite can `source` this file (to reach
# km_parse_capture / km_capture_canonical_hash / etc directly, e.g. to
# compute an expected idempotency key) without triggering argv dispatch or
# `exit`ing the sourcing shell.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  subcommand="${1:-}"
  [ $# -ge 1 ] && shift || true

  case "$subcommand" in
    capture) cmd_capture "$@"; exit $? ;;
    apply) cmd_apply "$@"; exit $? ;;
    index) cmd_index "$@"; exit $? ;;
    retire) cmd_retire "$@"; exit $? ;;
    purge) cmd_purge "$@"; exit $? ;;
    bootstrap) cmd_bootstrap "$@"; exit $? ;;
    unlock) cmd_unlock "$@"; exit $? ;;
    *)
      echo "ERROR: Usage: memory-write.sh <capture|apply|index|retire|purge|bootstrap|unlock> ..." >&2
      exit 2
      ;;
  esac
fi
