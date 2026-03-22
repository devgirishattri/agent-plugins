#!/usr/bin/env bash
# Checks for embedded TODO/FIXME/HACK markers in doc files
# Usage: check-todos.sh [docs-directory]
# Returns non-zero if markers found in files other than TODO.md and ISSUES.md
# Supported platforms: macOS, Linux

docs_dir="${1:-.}"
found=0

while IFS= read -r file; do
  bn=$(basename "$file")
  # Skip the dedicated tracker files — TODOs belong there
  if [ "$bn" = "TODO.md" ] || [ "$bn" = "ISSUES.md" ]; then
    continue
  fi

  # Match TODO:/FIXME:/HACK: markers — require colon to avoid matching noun usage ("TODO list", "see TODO")
  hits=$(grep -nE 'TODO:|FIXME:|HACK:' "$file" 2>/dev/null | head -10)
  if [ -n "$hits" ]; then
    echo "FOUND in $file:"
    echo "$hits" | sed 's/^/  /'
    echo ""
    found=$((found + 1))
  fi
done < <(find "$docs_dir" -name '*.md' -not -path '*/node_modules/*' 2>/dev/null)

if [ "$found" -gt 0 ]; then
  echo "Found embedded TODOs/issues in $found file(s)."
  echo "Move these to docs/TODO.md or docs/ISSUES.md instead."
  exit 1
else
  echo "No embedded TODOs found. All clean."
  exit 0
fi
