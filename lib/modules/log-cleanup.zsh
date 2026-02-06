# =============================================================================
# mac-ops: 로그 파일 정리 모듈
# ~/Library/Logs 하위의 오래된 로그 파일을 휴지통으로 이동
# .log, .crash, .diag, .spin, .hang 확장자 대상
# =============================================================================

# --- 기본 설정 ---
MAC_OPS_LOG_CLEANUP_MAX_AGE_DAYS=${MAC_OPS_LOG_CLEANUP_MAX_AGE_DAYS:-7}
MAC_OPS_DIAG_REPORT_MAX_AGE_DAYS=${MAC_OPS_DIAG_REPORT_MAX_AGE_DAYS:-14}

# --- 정리 대상 확장자 ---
MAC_OPS_LOG_EXTENSIONS=("log" "crash" "diag" "spin" "hang")

# -----------------------------------------------------------------------------
# 로그 정리 메인 함수
# ~/Library/Logs (7일), DiagnosticReports (14일) 기준 정리
# -----------------------------------------------------------------------------
mac_ops_log_cleanup() {
  local logs_dir="${HOME}/Library/Logs"
  local diag_dir="${HOME}/Library/Logs/DiagnosticReports"

  mac_ops_log_info "로그 정리 시작"

  # 1. ~/Library/Logs 일반 로그 정리
  if [[ -d "${logs_dir}" ]]; then
    _mac_ops_log_clean_dir "${logs_dir}" "${MAC_OPS_LOG_CLEANUP_MAX_AGE_DAYS}" "log-expired"
  else
    mac_ops_log_debug "로그 디렉토리가 존재하지 않습니다: ${logs_dir}"
  fi

  # 2. DiagnosticReports 정리 (더 긴 보관 기간 적용)
  if [[ -d "${diag_dir}" ]]; then
    _mac_ops_log_clean_dir "${diag_dir}" "${MAC_OPS_DIAG_REPORT_MAX_AGE_DAYS}" "diagnostic-report-expired"
  else
    mac_ops_log_debug "진단 보고서 디렉토리가 존재하지 않습니다: ${diag_dir}"
  fi

  mac_ops_log_info "로그 정리 완료"
  return 0
}

# -----------------------------------------------------------------------------
# 내부: 디렉토리에서 대상 확장자의 오래된 파일 정리
# 사용법: _mac_ops_log_clean_dir <디렉토리> <최대일수> <사유>
# -----------------------------------------------------------------------------
_mac_ops_log_clean_dir() {
  local target_dir="${1}"
  local max_age_days="${2}"
  local reason="${3}"
  local now_epoch
  local threshold_seconds=$((max_age_days * 86400))
  local find_args=()
  local first=true
  local count=0
  local file_list
  local mtime
  local age_seconds
  local file_size

  now_epoch=$(date +%s)

  mac_ops_log_info "${target_dir} 로그 정리 (기준: ${max_age_days}일 이상)"

  # find 명령으로 대상 확장자 파일 탐색
  # -name 조건을 OR로 연결하여 대상 확장자 매칭
  first=true
  for ext in "${MAC_OPS_LOG_EXTENSIONS[@]}"; do
    if [[ "${first}" == "true" ]]; then
      find_args+=("-name" "*.${ext}")
      first=false
    else
      find_args+=("-o" "-name" "*.${ext}")
    fi
  done

  count=0

  # find로 대상 파일 탐색
  file_list=$(find "${target_dir}" -maxdepth 5 -type f \( "${find_args[@]}" \) 2>/dev/null)

  if [[ -z "${file_list}" ]]; then
    mac_ops_log_debug "${target_dir}: 정리 대상 없음"
    return 0
  fi

  while IFS= read -r file_path; do
    [[ -z "${file_path}" ]] && continue

    # 파일 수정 시간 확인
    mtime=$(stat -f%m "${file_path}" 2>/dev/null)
    if [[ -z "${mtime}" || ! "${mtime}" =~ ^[0-9]+$ ]]; then
      mac_ops_log_debug "수정 시간 조회 실패: ${file_path}"
      continue
    fi

    # 경과 시간 계산
    age_seconds=$((now_epoch - mtime))
    if [[ ${age_seconds} -lt ${threshold_seconds} ]]; then
      continue
    fi

    # 안전성 체크
    if ! mac_ops_is_path_safe "${file_path}"; then
      continue
    fi

    # 크기 가드 체크
    if ! mac_ops_check_size_guard "${file_path}"; then
      continue
    fi

    # 파일 크기 기록
    file_size=$(mac_ops_get_dir_size "${file_path}")

    # 휴지통으로 이동
    if mac_ops_trash_move "${file_path}" "${reason}" "log-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done <<< "${file_list}"

  mac_ops_log_info "${target_dir}: ${count}개 로그 파일 정리됨"
  return 0
}
