#!/bin/zsh
# =============================================================================
# mac-ops 제거 스크립트
# crontab 항목 제거 + launchd 에이전트 제거
# =============================================================================

set -e

MAC_OPS_ROOT="$(cd "$(dirname "$0")" && pwd)"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.mac-ops.cleanup.plist"

# --- crontab 제거 ---
EXISTING_CRON=$(crontab -l 2>/dev/null || true)

if echo "${EXISTING_CRON}" | grep -q "mac-ops"; then
  echo "${EXISTING_CRON}" | grep -v "mac-ops" | crontab -
  echo "[OK] crontab에서 mac-ops 항목 제거"
else
  echo "[SKIP] crontab에 mac-ops 항목 없음"
fi

# --- launchd 에이전트 제거 ---
if [[ -f "${PLIST_PATH}" ]]; then
  launchctl unload "${PLIST_PATH}" 2>/dev/null || true
  rm -f "${PLIST_PATH}"
  echo "[OK] launchd 에이전트 제거: ${PLIST_PATH}"
else
  echo "[SKIP] launchd 에이전트 미설치"
fi

echo ""
echo "=========================================="
echo " mac-ops 제거 완료"
echo "=========================================="
echo ""
echo " 데이터 디렉토리(~/.mac-ops)는 유지됩니다."
echo " 완전 삭제: rm -rf ~/.mac-ops"
echo "=========================================="
