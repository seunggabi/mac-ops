# =============================================================================
# mac-ops: 중복 실행 방지
# PID 기반 락 파일로 동시 실행 차단, stale 락 자동 감지
# =============================================================================

# -----------------------------------------------------------------------------
# 락 획득
# 이미 실행 중이면 return 1, stale 락은 자동 제거 후 재획득
# -----------------------------------------------------------------------------
mac_ops_acquire_lock() {
  # 락 파일이 이미 존재하는 경우
  if [[ -f "${MAC_OPS_LOCK_FILE}" ]]; then
    local existing_pid
    existing_pid=$(cat "${MAC_OPS_LOCK_FILE}" 2>/dev/null)

    # PID가 유효한 숫자인지 확인
    if [[ -n "${existing_pid}" && "${existing_pid}" =~ ^[0-9]+$ ]]; then
      # 프로세스가 아직 살아있는지 확인
      if kill -0 "${existing_pid}" 2>/dev/null; then
        mac_ops_log_error "이미 실행 중입니다 (PID: ${existing_pid})"
        return 1
      else
        # stale 락 감지 - 프로세스가 죽었으므로 제거
        mac_ops_log_warn "stale 락 감지 (PID: ${existing_pid}), 제거 후 재획득합니다"
        rm -f "${MAC_OPS_LOCK_FILE}"
      fi
    else
      # PID가 유효하지 않은 락 파일 - 제거
      mac_ops_log_warn "잘못된 락 파일 감지, 제거합니다"
      rm -f "${MAC_OPS_LOCK_FILE}"
    fi
  fi

  # 새 락 파일 생성 (현재 PID 기록)
  print -- "$$" > "${MAC_OPS_LOCK_FILE}" 2>/dev/null
  if [[ $? -ne 0 ]]; then
    mac_ops_log_error "락 파일 생성 실패: ${MAC_OPS_LOCK_FILE}"
    return 1
  fi

  mac_ops_log_debug "락 획득 완료 (PID: $$)"
  return 0
}

# -----------------------------------------------------------------------------
# 락 해제
# -----------------------------------------------------------------------------
mac_ops_release_lock() {
  if [[ -f "${MAC_OPS_LOCK_FILE}" ]]; then
    local lock_pid
    lock_pid=$(cat "${MAC_OPS_LOCK_FILE}" 2>/dev/null)

    # 자기 자신의 락만 해제 (다른 프로세스의 락은 건드리지 않음)
    if [[ "${lock_pid}" == "$$" ]]; then
      rm -f "${MAC_OPS_LOCK_FILE}"
      mac_ops_log_debug "락 해제 완료 (PID: $$)"
    else
      mac_ops_log_warn "다른 프로세스의 락입니다 (PID: ${lock_pid}), 해제하지 않습니다"
    fi
  fi

  return 0
}

# -----------------------------------------------------------------------------
# 시그널 트랩 설정
# SIGTERM, SIGINT, SIGHUP, EXIT에 대해 정리 함수 등록
# -----------------------------------------------------------------------------
mac_ops_setup_trap() {
  trap '_mac_ops_cleanup_on_signal' TERM INT HUP EXIT
}

# -----------------------------------------------------------------------------
# 시그널 수신 시 정리 함수 (내부용)
# 락 해제 + 진행 중 작업 로깅
# -----------------------------------------------------------------------------
_mac_ops_cleanup_on_signal() {
  # 중복 실행 방지 (EXIT 트랩은 다른 시그널 후에도 발생)
  if [[ "${_MAC_OPS_CLEANUP_DONE:-false}" == "true" ]]; then
    return 0
  fi
  _MAC_OPS_CLEANUP_DONE=true

  mac_ops_log_warn "시그널 수신: 정리 작업을 시작합니다 (PID: $$)"

  # 락 해제
  mac_ops_release_lock

  mac_ops_log_info "정리 작업 완료"
}
