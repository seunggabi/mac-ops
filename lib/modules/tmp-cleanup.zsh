# =============================================================================
# mac-ops: 임시 파일 정리 모듈
# /tmp, /private/var/folders, ~/Library/Application Support/CrashReporter
# 각 경로별 다른 보관 기간 적용
# =============================================================================

# --- 기본 설정 ---
MAC_OPS_TMP_MAX_AGE_DAYS=${MAC_OPS_TMP_MAX_AGE_DAYS:-3}
MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS=${MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS:-7}
MAC_OPS_CRASH_MAX_AGE_DAYS=${MAC_OPS_CRASH_MAX_AGE_DAYS:-14}

# -----------------------------------------------------------------------------
# 임시 파일 정리 메인 함수
# /tmp (3일), /private/var/folders (7일), CrashReporter (14일) 기준 정리
# -----------------------------------------------------------------------------
mac_ops_tmp_cleanup() {
  mac_ops_log_info "임시 파일 정리 시작"

  # 1. /tmp 정리 (시스템 재부팅시 초기화되므로 보수적 처리)
  _mac_ops_tmp_clean_path "/tmp" "${MAC_OPS_TMP_MAX_AGE_DAYS}" "tmp-expired"

  # 2. /private/var/folders 정리 (사용자 영역만, sudo 없이 접근 가능한 것)
  _mac_ops_tmp_clean_var_folders "${MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS}"

  # 3. CrashReporter 정리
  local crash_dir="${HOME}/Library/Application Support/CrashReporter"
  if [[ -d "${crash_dir}" ]]; then
    _mac_ops_tmp_clean_path "${crash_dir}" "${MAC_OPS_CRASH_MAX_AGE_DAYS}" "crash-report-expired"
  fi

  mac_ops_log_info "임시 파일 정리 완료"
  return 0
}

# -----------------------------------------------------------------------------
# 내부: 지정 경로에서 오래된 파일 탐색 및 정리
# 사용법: _mac_ops_tmp_clean_path <경로> <최대일수> <사유>
# -----------------------------------------------------------------------------
_mac_ops_tmp_clean_path() {
  local target_dir="${1}"
  local max_age_days="${2}"
  local reason="${3}"
  local file_list
  local count=0
  local file_size

  if [[ ! -d "${target_dir}" ]]; then
    mac_ops_log_debug "경로가 존재하지 않습니다: ${target_dir}"
    return 0
  fi

  mac_ops_log_info "${target_dir} 정리 시작 (기준: ${max_age_days}일 이상)"

  # find로 오래된 파일 탐색 (수정 시간 기준)
  # -maxdepth 제한으로 너무 깊은 탐색 방지
  file_list=$(find "${target_dir}" -maxdepth 5 -type f -mtime "+${max_age_days}" 2>/dev/null)

  if [[ -z "${file_list}" ]]; then
    mac_ops_log_debug "${target_dir}: 정리 대상 없음"
    return 0
  fi

  count=0
  while IFS= read -r file_path; do
    [[ -z "${file_path}" ]] && continue

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
    if mac_ops_trash_move "${file_path}" "${reason}" "tmp-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done <<< "${file_list}"

  mac_ops_log_info "${target_dir}: ${count}개 파일 정리됨"
  return 0
}

# -----------------------------------------------------------------------------
# 내부: /private/var/folders 사용자 영역 정리
# sudo 없이 접근 가능한 현재 사용자의 임시 폴더만 처리
# 사용법: _mac_ops_tmp_clean_var_folders <최대일수>
# -----------------------------------------------------------------------------
_mac_ops_tmp_clean_var_folders() {
  local max_age_days="${1}"
  local var_folders="/private/var/folders"
  local file_list
  local count=0
  local file_size

  if [[ ! -d "${var_folders}" ]]; then
    mac_ops_log_debug "경로가 존재하지 않습니다: ${var_folders}"
    return 0
  fi

  mac_ops_log_info "/private/var/folders 정리 시작 (기준: ${max_age_days}일 이상)"

  # 현재 사용자가 접근 가능한 파일만 탐색
  # -readable 대신 2>/dev/null로 권한 오류 무시
  file_list=$(find "${var_folders}" -maxdepth 6 -type f -mtime "+${max_age_days}" \
    -user "${USER}" 2>/dev/null)

  if [[ -z "${file_list}" ]]; then
    mac_ops_log_debug "/private/var/folders: 정리 대상 없음"
    return 0
  fi

  count=0
  while IFS= read -r file_path; do
    [[ -z "${file_path}" ]] && continue

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
    if mac_ops_trash_move "${file_path}" "var-folders-expired" "tmp-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done <<< "${file_list}"

  mac_ops_log_info "/private/var/folders: ${count}개 파일 정리됨"
  return 0
}
