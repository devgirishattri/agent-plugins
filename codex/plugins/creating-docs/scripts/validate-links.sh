#!/usr/bin/env bash
# Validates cross-references in docs/*.md files
# Usage: validate-links.sh [docs-directory]
# Returns non-zero if broken links found
# Supported platforms: macOS, Linux
set -uo pipefail

docs_dir="${1:-.}"
broken=0
checked=0

# Find all markdown files in the docs directory
while IFS= read -r file; do
  # Extract markdown links to local .md files: [text](./path.md) or [text](path.md)
  # Uses sed instead of grep -P for macOS compatibility
  while read -r link; do
      # Resolve relative to the file's directory
      dir=$(dirname "$file")
      target="$dir/$link"
      checked=$((checked + 1))
      if [ ! -f "$target" ]; then
        echo "BROKEN: $file -> $link (expected at $target)"
        broken=$((broken + 1))
      fi
    done < <(grep -o '\[.*\]([^)]*.md)' "$file" 2>/dev/null | \
      sed 's/.*(\(.*\.md\))/\1/' | sed 's|^\./||' | \
      grep -v '^http')

  # Extract Related: header references like `doc1.md`, `doc2.md`
  while read -r ref; do
      dir=$(dirname "$file")
      target="$dir/$ref"
      checked=$((checked + 1))
      if [ ! -f "$target" ]; then
        echo "BROKEN: $file -> $ref (in Related header, expected at $target)"
        broken=$((broken + 1))
      fi
    done < <(grep '^\*\*Related\*\*:' "$file" 2>/dev/null | \
      grep -oE '`[^`]+\.md`' | tr -d '`')
done < <(find "$docs_dir" -name '*.md' -not -path '*/node_modules/*' 2>/dev/null)

if [ "$broken" -gt 0 ]; then
  echo ""
  echo "Found broken links. Update references or create missing docs."
  exit 1
else
  echo "All doc cross-references valid."
  exit 0
fi
