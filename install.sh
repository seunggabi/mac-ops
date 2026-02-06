#!/bin/zsh
# =============================================================================
# mac-ops installation script (wrapper)
# Delegate to bin/mac-ops install
# =============================================================================

set -e

MAC_OPS_ROOT="$(cd "$(dirname "$0")" && pwd)"
MAC_OPS_BIN="${MAC_OPS_ROOT}/bin/mac-ops"

# --- Check execute permission ---
if [[ ! -x "${MAC_OPS_BIN}" ]]; then
  chmod +x "${MAC_OPS_BIN}"
fi

# --- Delegate to bin/mac-ops install ---
exec "${MAC_OPS_BIN}" install
