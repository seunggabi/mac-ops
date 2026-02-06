# =============================================================================
# mac-ops: 좀비 프로세스 처리 모듈
# 상태가 Z인 좀비 프로세스를 탐지하고 부모 프로세스에 시그널 전송
# =============================================================================

# -----------------------------------------------------------------------------
# 좀비 프로세스 처리 메인 함수
# 1. ps aux로 좀비(Z) 프로세스 탐지
# 2. 부모(PPID) 확인 후 보호 프로세스가 아니면 SIGCHLD 전송
# 3. 3초 대기 후 아직 좀비이면 부모에게 SIGTERM 전송
# DRY_RUN 모드에서는 로그만 출력
# -----------------------------------------------------------------------------
mac_ops_zombie_killer() {
  local killed=0
  local zombie_list
  local zombie_count
  local ppid
  local parent_name
  local still_zombie

  mac_ops_log_info "좀비 프로세스 탐지 시작"

  # ps aux에서 상태가 Z인 프로세스 추출
  # 헤더 제외 (tail -n +2), 상태 필드(8번째)에 Z가 포함된 행 필터링
  zombie_list=$(ps aux | awk '$8 ~ /Z/ {print $2}' 2>/dev/null)

  if [[ -z "${zombie_list}" ]]; then
    mac_ops_log_info "좀비 프로세스가 없습니다"
    return 0
  fi

  # 좀비 수 카운트
  zombie_count=$(echo "${zombie_list}" | wc -l | tr -d ' ')
  mac_ops_log_info "좀비 프로세스 ${zombie_count}개 발견"

  while IFS= read -r zombie_pid; do
    [[ -z "${zombie_pid}" ]] && continue

    # PID 유효성 확인
    if [[ ! "${zombie_pid}" =~ ^[0-9]+$ ]]; then
      continue
    fi

    # 좀비의 부모 PID 확인
    ppid=$(ps -o ppid= -p "${zombie_pid}" 2>/dev/null | tr -d ' ')
    if [[ -z "${ppid}" || ! "${ppid}" =~ ^[0-9]+$ ]]; then
      mac_ops_log_debug "좀비 PID ${zombie_pid}: 부모 PID를 확인할 수 없습니다"
      continue
    fi

    # 부모 프로세스명 확인
    parent_name=$(ps -o comm= -p "${ppid}" 2>/dev/null | xargs basename 2>/dev/null)
    if [[ -z "${parent_name}" ]]; then
      mac_ops_log_debug "좀비 PID ${zombie_pid}: 부모 프로세스명을 확인할 수 없습니다 (PPID: ${ppid})"
      continue
    fi

    # 보호 프로세스 체크 (return 0=비보호, return 1=보호)
    if ! mac_ops_is_process_protected "${parent_name}" 2>/dev/null; then
      mac_ops_log_warn "좀비 PID ${zombie_pid}: 부모 ${parent_name}(${ppid})은 보호 프로세스이므로 건너뜁니다"
      continue
    fi

    mac_ops_log_info "좀비 PID ${zombie_pid} 처리 중 (부모: ${parent_name}, PPID: ${ppid})"

    # DRY_RUN 모드
    if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
      mac_ops_log_info "[DRY_RUN] 부모 PID ${ppid}(${parent_name})에 SIGCHLD 전송 예정"
      killed=$((killed + 1))
      continue
    fi

    # 1단계: 부모에게 SIGCHLD 전송 (좀비 수거 유도)
    mac_ops_log_info "부모 PID ${ppid}(${parent_name})에 SIGCHLD 전송"
    kill -SIGCHLD "${ppid}" 2>/dev/null

    # 3초 대기
    sleep 3

    # 좀비가 아직 존재하는지 확인
    still_zombie=$(ps -o stat= -p "${zombie_pid}" 2>/dev/null | tr -d ' ')
    if [[ "${still_zombie}" == *Z* ]]; then
      # 2단계: 부모에게 SIGTERM 전송
      mac_ops_log_warn "좀비 PID ${zombie_pid} 여전히 존재. 부모 PID ${ppid}(${parent_name})에 SIGTERM 전송"
      kill -SIGTERM "${ppid}" 2>/dev/null
    else
      mac_ops_log_info "좀비 PID ${zombie_pid} 정상 수거됨 (SIGCHLD)"
    fi

    killed=$((killed + 1))
  done <<< "${zombie_list}"

  # 전역 카운터 누적
  MAC_OPS_KILLED_COUNT=$((${MAC_OPS_KILLED_COUNT:-0} + killed))

  mac_ops_log_info "좀비 프로세스 처리 완료: ${killed}개 처리됨"
  return 0
}
