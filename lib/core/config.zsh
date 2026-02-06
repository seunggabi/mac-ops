# =============================================================================
# mac-ops: 설정 로더
# 기본 경로 정의 및 config.plist 로드
# =============================================================================

# --- 기본 경로 ---
MAC_OPS_HOME="${MAC_OPS_HOME:-${HOME}/.mac-ops}"
MAC_OPS_TRASH_DIR="${MAC_OPS_TRASH_DIR:-${MAC_OPS_HOME}/.trash}"
MAC_OPS_META_DIR="${MAC_OPS_META_DIR:-${MAC_OPS_HOME}/.metadata}"
MAC_OPS_LOG_DIR="${MAC_OPS_LOG_DIR:-${MAC_OPS_HOME}/.logs}"
MAC_OPS_LOCK_FILE="${MAC_OPS_LOCK_FILE:-${MAC_OPS_HOME}/mac-ops.lock}"
MAC_OPS_CONFIG_FILE="${MAC_OPS_CONFIG_FILE:-${MAC_OPS_HOME}/config.plist}"

# --- 기본 플래그 ---
MAC_OPS_DRY_RUN=${MAC_OPS_DRY_RUN:-false}
MAC_OPS_VERBOSE=${MAC_OPS_VERBOSE:-false}
MAC_OPS_FORCE=${MAC_OPS_FORCE:-false}
MAC_OPS_SCHEDULED=${MAC_OPS_SCHEDULED:-false}

# --- 기본 설정값 ---
MAC_OPS_TRASH_RETENTION_HOURS=${MAC_OPS_TRASH_RETENTION_HOURS:-72}

# -----------------------------------------------------------------------------
# 필요한 디렉토리 생성
# -----------------------------------------------------------------------------
mac_ops_init_dirs() {
  local dirs=(
    "${MAC_OPS_HOME}"
    "${MAC_OPS_TRASH_DIR}"
    "${MAC_OPS_META_DIR}"
    "${MAC_OPS_LOG_DIR}"
  )

  for dir in "${dirs[@]}"; do
    if [[ ! -d "${dir}" ]]; then
      mkdir -p "${dir}" 2>/dev/null
      if [[ $? -ne 0 ]]; then
        print -- "[ERROR] 디렉토리 생성 실패: ${dir}" >&2
        return 1
      fi
    fi
  done

  return 0
}

# -----------------------------------------------------------------------------
# config.plist에서 설정 로드 (plutil 사용)
# 파일이 없으면 기본값을 유지한다.
# -----------------------------------------------------------------------------
mac_ops_load_config() {
  # config.plist가 없으면 기본값 사용
  if [[ ! -f "${MAC_OPS_CONFIG_FILE}" ]]; then
    return 0
  fi

  # plist 유효성 검증
  if ! plutil -lint "${MAC_OPS_CONFIG_FILE}" &>/dev/null; then
    print -- "[ERROR] config.plist 형식이 잘못되었습니다: ${MAC_OPS_CONFIG_FILE}" >&2
    return 1
  fi

  # 각 설정값 로드 (키가 없으면 기본값 유지)
  local val

  val=$(plutil -extract DryRun raw "${MAC_OPS_CONFIG_FILE}" 2>/dev/null)
  [[ -n "${val}" ]] && MAC_OPS_DRY_RUN="${val}"

  val=$(plutil -extract Verbose raw "${MAC_OPS_CONFIG_FILE}" 2>/dev/null)
  [[ -n "${val}" ]] && MAC_OPS_VERBOSE="${val}"

  val=$(plutil -extract Force raw "${MAC_OPS_CONFIG_FILE}" 2>/dev/null)
  [[ -n "${val}" ]] && MAC_OPS_FORCE="${val}"

  val=$(plutil -extract Scheduled raw "${MAC_OPS_CONFIG_FILE}" 2>/dev/null)
  [[ -n "${val}" ]] && MAC_OPS_SCHEDULED="${val}"

  val=$(plutil -extract TrashRetentionHours raw "${MAC_OPS_CONFIG_FILE}" 2>/dev/null)
  [[ -n "${val}" ]] && MAC_OPS_TRASH_RETENTION_HOURS="${val}"

  return 0
}
