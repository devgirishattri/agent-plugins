#!/usr/bin/env bash
# Minimal native Codex stand-in for session-manager smoke tests.
set -euo pipefail

: "${SESSION_MANAGER_TEST_LOG:?SESSION_MANAGER_TEST_LOG must be set}"

printf 'CODEX_HOME=%s' "${CODEX_HOME:-}"
for arg in "$@"; do
    printf '\t%s' "$arg"
done
printf '\n'

{
    printf 'CODEX_HOME=%s' "${CODEX_HOME:-}"
    for arg in "$@"; do
        printf '\t%s' "$arg"
    done
    printf '\n'
} >> "$SESSION_MANAGER_TEST_LOG"
