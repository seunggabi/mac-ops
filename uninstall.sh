#!/bin/zsh
# =============================================================================
# mac-ops uninstall script
# Remove crontab entry + uninstall launchd agent
# =============================================================================

set -e

MAC_OPS_ROOT="$(cd "$(dirname "$0")" && pwd)"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.mac-ops.cleanup.plist"

# --- Remove crontab ---
EXISTING_CRON=$(crontab -l 2>/dev/null || true)

if echo "${EXISTING_CRON}" | grep -q "mac-ops"; then
  echo "${EXISTING_CRON}" | grep -v "mac-ops" | crontab -
  echo "[OK] Removed mac-ops entry from crontab"
else
  echo "[SKIP] No mac-ops entry in crontab"
fi

# --- Remove launchd agent ---
if [[ -f "${PLIST_PATH}" ]]; then
  launchctl unload "${PLIST_PATH}" 2>/dev/null || true
  rm -f "${PLIST_PATH}"
  echo "[OK] Removed launchd agent: ${PLIST_PATH}"
else
  echo "[SKIP] launchd agent not installed"
fi

echo ""
echo "=========================================="
echo " mac-ops uninstalled"
echo "=========================================="
echo ""
echo " Data directory (~/.mac-ops) will be preserved."
echo " Complete removal: rm -rf ~/.mac-ops"
echo "=========================================="
