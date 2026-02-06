# =============================================================================
# mac-ops: 고아 프로세스 처리 모듈
# PPID=1이면서 launchctl에 등록되지 않은 오래된 프로세스를 종료
# =============================================================================

# --- 기본 설정 ---
MAC_OPS_ORPHAN_MIN_RUNNING_HOURS=${MAC_OPS_ORPHAN_MIN_RUNNING_HOURS:-24}

# -----------------------------------------------------------------------------
# 고아 프로세스 처리 메인 함수
# 1. PPID=1인 프로세스 탐지
# 2. launchctl에 등록되지 않은 프로세스 필터링
# 3. MinRunningHours 이상 실행 중인 것만 대상
# 4. 보호 프로세스 체크 후 SIGTERM -> 5초 대기 -> SIGKILL
# DRY_RUN 모드에서는 로그만 출력
# -----------------------------------------------------------------------------
mac_ops_orphan_killer() {
  local min_hours="${MAC_OPS_ORPHAN_MIN_RUNNING_HOURS}"

  mac_ops_log_info "고아 프로세스 탐지 시작 (기준: ${min_hours}시간 이상 실행)"

  local killed=0

  # launchctl에 등록된 서비스 목록 추출
  # launchctl list의 3번째 컬럼(Label)을 수집
  local launchctl_services
  launchctl_services=$(launchctl list 2>/dev/null | awk 'NR>1 {print $3}')

  # PPID=1인 프로세스 목록 (pid, ppid, elapsed time, command)
  local orphan_list
  orphan_list=$(ps -eo pid=,ppid=,etime=,comm= 2>/dev/null | awk '$2 == 1 {print}')

  if [[ -z "${orphan_list}" ]]; then
    mac_ops_log_info "고아 프로세스가 없습니다"
    return 0
  fi

  # 루프 내 변수 선언 (한 번만)
  local pid="" ppid="" etime="" comm="" proc_name=""
  local is_registered=false
  local running_hours=""

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue

    # 필드 파싱 (read로 한 번에 분리, stdout 차단)
    pid=""; ppid=""; etime=""; comm=""; proc_name=""
    read -r pid ppid etime comm <<< "${line}"

    # PID 유효성 확인
    if [[ -z "${pid}" || ! "${pid}" =~ ^[0-9]+$ ]]; then
      continue
    fi

    # 프로세스명 추출 (경로에서 basename)
    proc_name="${comm##*/}"
    if [[ -z "${proc_name}" ]]; then
      continue
    fi

    # 경로 없는 프로세스 건너뜀 (시스템 데몬: autofsd, aslmanager 등)
    if [[ "${comm}" != /* ]]; then
      mac_ops_log_debug "시스템 데몬 건너뜀 (경로 없음): ${proc_name} (PID: ${pid})"
      continue
    fi

    # 시스템 바이너리 경로 필터링
    if [[ "${comm}" == /System/* || \
          "${comm}" == /usr/libexec/* || \
          "${comm}" == /usr/sbin/* || \
          "${comm}" == /usr/bin/* || \
          "${comm}" == /Library/Apple/* || \
          "${comm}" == /Library/PrivilegedHelperTools/* || \
          "${comm}" == /Library/Application\ Support/* || \
          "${comm}" == /Library/Developer/* || \
          "${comm}" == /sbin/* || \
          "${comm}" == /bin/* || \
          "${comm}" == /kernel* || \
          "${comm}" == /Applications/* ]]; then
      mac_ops_log_debug "시스템/서비스 프로세스 건너뜀: ${proc_name} (${comm})"
      continue
    fi

    # macOS 앱 번들 프로세스 건너뜀 (*.app/Contents/MacOS/*)
    if [[ "${comm}" == *".app/Contents/"* ]]; then
      mac_ops_log_debug "앱 번들 프로세스 건너뜀: ${proc_name} (${comm})"
      continue
    fi

    # com.apple.* 프로세스명 필터링
    if [[ "${proc_name}" == com.apple.* ]]; then
      mac_ops_log_debug "Apple 서비스 건너뜀: ${proc_name} (PID: ${pid})"
      continue
    fi

    # 보호 프로세스 체크 (return 0=비보호, return 1=보호)
    if ! mac_ops_is_process_protected "${proc_name}" 2>/dev/null; then
      mac_ops_log_debug "보호 프로세스 건너뜀: ${proc_name} (PID: ${pid})"
      continue
    fi

    # launchctl에 등록된 서비스인지 확인
    # 프로세스명이 서비스 레이블에 포함되어 있으면 건너뜀
    is_registered=false
    if echo "${launchctl_services}" | grep -qi "${proc_name}" 2>/dev/null; then
      is_registered=true
    fi
    if [[ "${is_registered}" == "true" ]]; then
      mac_ops_log_debug "launchctl 등록 서비스 건너뜀: ${proc_name} (PID: ${pid})"
      continue
    fi

    # 실행 시간 파싱 (etime 형식: [[DD-]HH:]MM:SS)
    running_hours=""
    running_hours=$(_mac_ops_parse_etime_hours "${etime}")
    if [[ -z "${running_hours}" ]]; then
      mac_ops_log_debug "실행 시간 파싱 실패: ${proc_name} (PID: ${pid}, etime: ${etime})"
      continue
    fi

    # MinRunningHours 미만이면 건너뜀
    if [[ ${running_hours} -lt ${min_hours} ]]; then
      continue
    fi

    mac_ops_log_info "고아 프로세스 발견: ${proc_name} (PID: ${pid}, 실행: ${running_hours}시간)"

    # DRY_RUN 모드
    if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
      mac_ops_log_info "[DRY_RUN] PID ${pid}(${proc_name})에 SIGTERM 전송 예정"
      killed=$((killed + 1))
      continue
    fi

    # 1단계: SIGTERM 전송
    mac_ops_log_info "PID ${pid}(${proc_name})에 SIGTERM 전송"
    kill -SIGTERM "${pid}" 2>/dev/null

    # 5초 대기
    sleep 5

    # 프로세스가 아직 존재하는지 확인
    if kill -0 "${pid}" 2>/dev/null; then
      # 2단계: SIGKILL 전송
      mac_ops_log_warn "PID ${pid}(${proc_name}) 여전히 존재. SIGKILL 전송"
      kill -SIGKILL "${pid}" 2>/dev/null
    else
      mac_ops_log_info "PID ${pid}(${proc_name}) 정상 종료됨 (SIGTERM)"
    fi

    killed=$((killed + 1))
  done <<< "${orphan_list}"

  # 전역 카운터 누적
  MAC_OPS_KILLED_COUNT=$((${MAC_OPS_KILLED_COUNT:-0} + killed))

  mac_ops_log_info "고아 프로세스 처리 완료: ${killed}개 처리됨"
  return 0
}

# -----------------------------------------------------------------------------
# 내부: etime 문자열을 시간(hours) 정수로 변환
# etime 형식: [[DD-]HH:]MM:SS
# 예: "02:30" -> 0, "01:02:30" -> 1, "3-01:02:30" -> 73
# 사용법: _mac_ops_parse_etime_hours <etime>
# -----------------------------------------------------------------------------
_mac_ops_parse_etime_hours() {
  local etime="${1}"
  local days=0
  local hours=0
  local minutes=0

  # DD-HH:MM:SS 형식 (일 포함)
  if [[ "${etime}" == *-* ]]; then
    days=${etime%%-*}
    etime=${etime#*-}
  fi

  # 콜론 수에 따라 파싱
  local colon_count
  colon_count=$(echo "${etime}" | tr -cd ':' | wc -c | tr -d ' ')

  if [[ ${colon_count} -eq 2 ]]; then
    # HH:MM:SS
    hours=$(echo "${etime}" | cut -d: -f1)
    minutes=$(echo "${etime}" | cut -d: -f2)
  elif [[ ${colon_count} -eq 1 ]]; then
    # MM:SS
    minutes=$(echo "${etime}" | cut -d: -f1)
  fi

  # 앞의 0 제거 (08 -> 8 등, 산술 오류 방지)
  days=$((10#${days}))
  hours=$((10#${hours}))
  minutes=$((10#${minutes}))

  local total_hours=$((days * 24 + hours))
  print -- "${total_hours}"
}
