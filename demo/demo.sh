#!/bin/bash
# mac-ops demo script
# Record with: asciinema rec demo.cast -c "bash demo/demo.sh"
# Convert to GIF: agg demo.cast demo.gif

# Typing simulation
type_cmd() {
  local cmd="$1"
  echo -n "$ "
  for ((i=0; i<${#cmd}; i++)); do
    echo -n "${cmd:$i:1}"
    sleep 0.05
  done
  echo ""
  sleep 0.3
  eval "$cmd"
  sleep 1.5
}

clear
echo "╔══════════════════════════════════════╗"
echo "║     mac-ops - macOS Optimizer        ║"
echo "╚══════════════════════════════════════╝"
echo ""
sleep 2

# Show version
type_cmd "bin/mac-ops version"

# Show help
type_cmd "bin/mac-ops help"

# Analyze disk space
type_cmd "bin/mac-ops analyze"

# Dry run
type_cmd "bin/mac-ops run --dry-run --module=cache"

# Check status
type_cmd "bin/mac-ops status"

echo ""
echo "🎉 Demo complete! Visit: https://github.com/seunggabi/mac-ops"
sleep 3
