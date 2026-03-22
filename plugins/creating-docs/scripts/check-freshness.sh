#!/usr/bin/env bash
# Checks if docs are stale relative to the code they reference
# Usage: check-freshness.sh [docs-directory] [days-threshold]
# Flags docs not modified in N days (default: 30) when referenced code has changed
# Supported platforms: macOS, Linux

docs_dir="${1:-.}"
threshold="${2:-30}"
stale=0

# Must be in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo "Not a git repository. Skipping freshness check."
  exit 0
fi

threshold_date=$(date -d "$threshold days ago" +%Y-%m-%d 2>/dev/null || date -v-${threshold}d +%Y-%m-%d 2>/dev/null)

while IFS= read -r doc; do
  # Get the doc's last modification date in git
  doc_last_modified=$(git log -1 --format="%ai" -- "$doc" 2>/dev/null | cut -d' ' -f1)

  if [ -z "$doc_last_modified" ]; then
    continue  # Not tracked by git
  fi

  # Check if doc is older than threshold
  if [[ "$doc_last_modified" < "$threshold_date" ]]; then
    # Extract referenced file paths from the doc (backtick-wrapped paths containing / or .ts/.js/.py etc)
    refs=$(grep -oE '`[a-zA-Z][a-zA-Z0-9_/.-]+\.(ts|js|tsx|jsx|py|prisma|sql|yaml|yml|json)`' "$doc" 2>/dev/null | tr -d '`' | sort -u)

    for ref in $refs; do
      # Check if any matching file was modified after the doc
      matches=$(git ls-files "*$ref" 2>/dev/null)
      for match in $matches; do
        code_last_modified=$(git log -1 --format="%ai" -- "$match" 2>/dev/null | cut -d' ' -f1)
        if [ -n "$code_last_modified" ] && [[ "$code_last_modified" > "$doc_last_modified" ]]; then
          echo "STALE: $doc (last updated: $doc_last_modified)"
          echo "  -> $match changed on $code_last_modified"
          stale=$((stale + 1))
          break 2  # One stale reference is enough to flag the doc
        fi
      done
    done
  fi
done < <(find "$docs_dir" -name '*.md' -not -name 'TODO.md' -not -name 'ISSUES.md' -not -path '*/node_modules/*' 2>/dev/null)

if [ "$stale" -gt 0 ]; then
  echo ""
  echo "Found $stale stale doc(s). Review and update them."
  exit 1
else
  echo "All docs are fresh."
  exit 0
fi
