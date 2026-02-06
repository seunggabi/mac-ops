#!/bin/zsh
# =============================================================================
# mac-ops 설치 스크립트
# crontab 등록 + 초기 디렉토리 생성
# =============================================================================

set -e

MAC_OPS_ROOT="$(cd "$(dirname "$0")" && pwd)"
MAC_OPS_BIN="${MAC_OPS_ROOT}/bin/mac-ops"
LOG_DIR="${HOME}/.mac-ops/.logs"
CRON_SCHEDULE="0 * * * *"
CRON_ENTRY="${CRON_SCHEDULE} ${MAC_OPS_BIN} run --scheduled >> ${LOG_DIR}/cron.log 2>&1"

# --- 실행 권한 확인 ---
if [[ ! -x "${MAC_OPS_BIN}" ]]; then
  chmod +x "${MAC_OPS_BIN}"
  echo "[OK] 실행 권한 부여: ${MAC_OPS_BIN}"
fi

# --- 로그 디렉토리 생성 ---
mkdir -p "${LOG_DIR}"
echo "[OK] 로그 디렉토리: ${LOG_DIR}"

# --- crontab 등록 (없을 때만) ---
EXISTING_CRON=$(crontab -l 2>/dev/null || true)

if echo "${EXISTING_CRON}" | grep -q "mac-ops"; then
  echo "[SKIP] mac-ops crontab 이미 등록되어 있습니다"
else
  (echo "${EXISTING_CRON}"; echo "# mac-ops"; echo "${CRON_ENTRY}") | crontab -
  echo "[OK] crontab 등록 완료 (매시간 실행)"
fi

# --- 결과 확인 ---
echo ""
echo "=========================================="
echo " mac-ops 설치 완료"
echo "=========================================="
echo ""
echo " 실행 경로: ${MAC_OPS_BIN}"
echo " 스케줄:    매시간 (${CRON_SCHEDULE})"
echo " 로그:      ${LOG_DIR}/cron.log"
echo ""
echo " 수동 실행:  ${MAC_OPS_BIN} run --dry-run"
echo " 제거:       ${MAC_OPS_ROOT}/uninstall.sh"
echo ""
echo " [주의] Full Disk Access 권한이 필요합니다."
echo " 시스템 설정 > 개인정보 보호 및 보안 > Full Disk Access"
echo " 에서 터미널 앱을 추가해주세요."
echo "=========================================="
