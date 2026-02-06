# =============================================================================
# mac-ops: 디스크 공간 모니터링
# 사용량 조회, 공간 확인, 긴급 퍼지, 볼륨 비교
# =============================================================================

# -----------------------------------------------------------------------------
# 현재 디스크 사용량 퍼센트 반환
# 루트 볼륨(/) 기준
# -----------------------------------------------------------------------------
mac_ops_get_disk_usage() {
  local usage
  usage=$(df -h / | tail -1 | awk '{gsub(/%/,"",$5); print $5}')

  if [[ -z "${usage}" || ! "${usage}" =~ ^[0-9]+$ ]]; then
    mac_ops_log_error "디스크 사용량 조회 실패"
    return 1
  fi

  print -- "${usage}"
  return 0
}

# -----------------------------------------------------------------------------
# 남은 디스크 공간 바이트 반환
# 루트 볼륨(/) 기준, 512바이트 블록 -> 바이트 변환
# -----------------------------------------------------------------------------
mac_ops_get_disk_available() {
  local available_blocks
  available_blocks=$(df / | tail -1 | awk '{print $4}')

  if [[ -z "${available_blocks}" || ! "${available_blocks}" =~ ^[0-9]+$ ]]; then
    mac_ops_log_error "남은 디스크 공간 조회 실패"
    return 1
  fi

  # df는 기본적으로 512바이트 블록 단위
  local available_bytes=$((available_blocks * 512))
  print -- "${available_bytes}"
  return 0
}

# -----------------------------------------------------------------------------
# 필요한 디스크 공간이 있는지 확인
# 사용법: mac_ops_check_disk_space <필요_바이트>
# -----------------------------------------------------------------------------
mac_ops_check_disk_space() {
  local required_bytes="${1}"

  if [[ -z "${required_bytes}" || ! "${required_bytes}" =~ ^[0-9]+$ ]]; then
    mac_ops_log_error "사용법: mac_ops_check_disk_space <필요_바이트>"
    return 1
  fi

  local available_bytes
  available_bytes=$(mac_ops_get_disk_available)
  if [[ $? -ne 0 ]]; then
    return 1
  fi

  if [[ ${available_bytes} -lt ${required_bytes} ]]; then
    local required_mb=$((required_bytes / 1048576))
    local available_mb=$((available_bytes / 1048576))
    mac_ops_log_error "디스크 공간 부족: 필요 ${required_mb}MB, 가용 ${available_mb}MB"
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# 디렉토리/파일 크기 바이트 반환 (du 사용)
# 사용법: mac_ops_get_dir_size <경로>
# -----------------------------------------------------------------------------
mac_ops_get_dir_size() {
  local target_path="${1}"

  if [[ -z "${target_path}" || ! -e "${target_path}" ]]; then
    print -- "0"
    return 1
  fi

  local size_bytes
  # du -sk: 킬로바이트 단위, 총합만
  size_bytes=$(du -sk "${target_path}" 2>/dev/null | awk '{print $1}')

  if [[ -z "${size_bytes}" || ! "${size_bytes}" =~ ^[0-9]+$ ]]; then
    print -- "0"
    return 1
  fi

  # KB -> 바이트 변환
  print -- "$((size_bytes * 1024))"
  return 0
}

# -----------------------------------------------------------------------------
# 긴급 퍼지
# 디스크 95% 이상 사용 시 만료된 trash 즉시 삭제
# -----------------------------------------------------------------------------
mac_ops_emergency_purge() {
  local usage
  usage=$(mac_ops_get_disk_usage)
  if [[ $? -ne 0 ]]; then
    return 1
  fi

  if [[ ${usage} -lt 95 ]]; then
    mac_ops_log_debug "디스크 사용량 ${usage}%: 긴급 퍼지 불필요"
    return 0
  fi

  mac_ops_log_warn "디스크 사용량 ${usage}%: 긴급 퍼지를 시작합니다"

  # 만료된 항목 삭제
  mac_ops_trash_expire

  # 삭제 후 재확인
  local new_usage
  new_usage=$(mac_ops_get_disk_usage)
  mac_ops_log_info "긴급 퍼지 완료: ${usage}% -> ${new_usage}%"

  return 0
}

# -----------------------------------------------------------------------------
# 두 경로가 같은 볼륨인지 확인
# 사용법: mac_ops_is_same_volume <경로1> <경로2>
# 같은 볼륨이면 0, 다르면 1
# -----------------------------------------------------------------------------
mac_ops_is_same_volume() {
  local path1="${1}"
  local path2="${2}"

  if [[ -z "${path1}" || -z "${path2}" ]]; then
    mac_ops_log_error "사용법: mac_ops_is_same_volume <경로1> <경로2>"
    return 1
  fi

  # 존재하는 가장 가까운 상위 디렉토리로 올라가기
  local check1="${path1}"
  while [[ ! -e "${check1}" && "${check1}" != "/" ]]; do
    check1=$(dirname "${check1}")
  done

  local check2="${path2}"
  while [[ ! -e "${check2}" && "${check2}" != "/" ]]; do
    check2=$(dirname "${check2}")
  done

  # df로 마운트 포인트 비교
  local vol1 vol2
  vol1=$(df "${check1}" 2>/dev/null | tail -1 | awk '{print $1}')
  vol2=$(df "${check2}" 2>/dev/null | tail -1 | awk '{print $1}')

  if [[ -z "${vol1}" || -z "${vol2}" ]]; then
    mac_ops_log_error "볼륨 정보 조회 실패"
    return 1
  fi

  if [[ "${vol1}" != "${vol2}" ]]; then
    mac_ops_log_debug "다른 볼륨: ${path1}(${vol1}) != ${path2}(${vol2})"
    return 1
  fi

  return 0
}
