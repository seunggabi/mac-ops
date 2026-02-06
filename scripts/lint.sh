#!/bin/bash
# mac-ops shellcheck linter
# Runs shellcheck on all zsh scripts

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXIT_CODE=0

echo "Running shellcheck on mac-ops scripts..."
echo ""

# Find all .zsh files and bin/mac-ops
FILES=(
  "${SCRIPT_DIR}/bin/mac-ops"
  "${SCRIPT_DIR}/install.sh"
  "${SCRIPT_DIR}/uninstall.sh"
)

# Add all .zsh files
while IFS= read -r f; do
  FILES+=("$f")
done < <(find "${SCRIPT_DIR}/lib" -name "*.zsh" -type f)

for file in "${FILES[@]}"; do
  if shellcheck --shell=bash --severity=warning \
    --exclude=SC1090,SC1091,SC2034,SC2154,SC2086,SC2196,SC2197,SC2199,SC2206,SC2207,SC2128 \
    "$file" 2>/dev/null; then
    echo "  PASS: $(basename "$file")"
  else
    echo "  WARN: $(basename "$file")"
    EXIT_CODE=1
  fi
done

echo ""
if [ $EXIT_CODE -eq 0 ]; then
  echo "All files passed shellcheck!"
else
  echo "Some files have warnings (see above)"
fi

exit $EXIT_CODE
