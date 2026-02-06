# =============================================================================
# mac-ops: 로깅 시스템
# 파일 + stdout 동시 출력, 로그 레벨 지원, 로테이션
# =============================================================================

# 로그 파일 경로
MAC_OPS_LOG_FILE="${MAC_OPS_LOG_DIR}/mac-ops.log"

# 로그 레벨 상수
typeset -A MAC_OPS_LOG_LEVELS
MAC_OPS_LOG_LEVELS=(
  DEBUG 0
  INFO  1
  WARN  2
  ERROR 3
)

# 로그 로테이션 설정
MAC_OPS_LOG_MAX_SIZE=5242880   # 5MB
MAC_OPS_LOG_MAX_FILES=7        # 최대 7개 보관

# -----------------------------------------------------------------------------
# 핵심 로그 함수
# 사용법: mac_ops_log <LEVEL> <메시지>
# -----------------------------------------------------------------------------
mac_ops_log() {
  local level="${1}"
  local message="${2}"

  # 레벨 유효성 검증
  if [[ -z "${MAC_OPS_LOG_LEVELS[${level}]+_}" ]]; then
    level="INFO"
  fi

  # DEBUG 레벨은 VERBOSE 모드에서만 출력
  if [[ "${level}" == "DEBUG" && "${MAC_OPS_VERBOSE}" != "true" ]]; then
    return 0
  fi

  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local formatted="[${timestamp}] [${level}] ${message}"

  # 파일 출력 (로그 디렉토리가 존재하면)
  if [[ -d "${MAC_OPS_LOG_DIR}" ]]; then
    print -- "${formatted}" >> "${MAC_OPS_LOG_FILE}" 2>/dev/null
  fi

  # stdout 출력 (SCHEDULED 모드가 아닐 때만)
  if [[ "${MAC_OPS_SCHEDULED}" != "true" ]]; then
    if [[ "${level}" == "ERROR" || "${level}" == "WARN" ]]; then
      print -- "${formatted}" >&2
    else
      print -- "${formatted}"
    fi
  fi

  return 0
}

# -----------------------------------------------------------------------------
# 단축 로그 함수들
# -----------------------------------------------------------------------------
mac_ops_log_info() {
  mac_ops_log "INFO" "${1}"
}

mac_ops_log_warn() {
  mac_ops_log "WARN" "${1}"
}

mac_ops_log_error() {
  mac_ops_log "ERROR" "${1}"
}

mac_ops_log_debug() {
  mac_ops_log "DEBUG" "${1}"
}

# -----------------------------------------------------------------------------
# 로그 파일 로테이션
# 5MB 초과 시 실행, 최대 7개 보관
# mac-ops.log -> mac-ops.log.1 -> ... -> mac-ops.log.7 (삭제)
# -----------------------------------------------------------------------------
mac_ops_log_rotate() {
  # 로그 파일이 없으면 할 일 없음
  if [[ ! -f "${MAC_OPS_LOG_FILE}" ]]; then
    return 0
  fi

  # 현재 로그 파일 크기 확인 (바이트)
  local file_size
  file_size=$(stat -f%z "${MAC_OPS_LOG_FILE}" 2>/dev/null || echo 0)

  # 5MB 이하면 로테이션 불필요
  if [[ ${file_size} -le ${MAC_OPS_LOG_MAX_SIZE} ]]; then
    return 0
  fi

  # 가장 오래된 로그 삭제 (최대 보관 수 초과분)
  local i=${MAC_OPS_LOG_MAX_FILES}
  if [[ -f "${MAC_OPS_LOG_FILE}.${i}" ]]; then
    rm -f "${MAC_OPS_LOG_FILE}.${i}"
  fi

  # 기존 로그 파일 번호 증가 (역순으로)
  i=$((MAC_OPS_LOG_MAX_FILES - 1))
  while [[ ${i} -ge 1 ]]; do
    if [[ -f "${MAC_OPS_LOG_FILE}.${i}" ]]; then
      mv "${MAC_OPS_LOG_FILE}.${i}" "${MAC_OPS_LOG_FILE}.$((i + 1))"
    fi
    i=$((i - 1))
  done

  # 현재 로그를 .1로 이동
  mv "${MAC_OPS_LOG_FILE}" "${MAC_OPS_LOG_FILE}.1"

  # 새 로그 파일 생성
  touch "${MAC_OPS_LOG_FILE}"

  return 0
}
