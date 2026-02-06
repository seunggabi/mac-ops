# =============================================================================
# mac-ops: 휴지통 관리
# 안전한 파일 이동, 메타데이터 관리, 만료/복원/목록 기능
# =============================================================================

# -----------------------------------------------------------------------------
# 파일/디렉토리를 휴지통으로 이동
# 사용법: mac_ops_trash_move <원본경로> <사유> <모듈명>
# 트랜잭션 패턴: metadata를 in_progress로 먼저 생성 -> mv -> completed로 업데이트
# -----------------------------------------------------------------------------
mac_ops_trash_move() {
  local source_path="${1}"
  local reason="${2}"
  local module_name="${3}"

  # 인자 검증
  if [[ -z "${source_path}" || -z "${reason}" || -z "${module_name}" ]]; then
    mac_ops_log_error "사용법: mac_ops_trash_move <경로> <사유> <모듈명>"
    return 1
  fi

  # 원본 존재 확인
  if [[ ! -e "${source_path}" ]]; then
    mac_ops_log_error "원본이 존재하지 않습니다: ${source_path}"
    return 1
  fi

  # 절대 경로로 변환
  local abs_source
  abs_source=$(cd "$(dirname "${source_path}")" 2>/dev/null && print -- "${PWD}/$(basename "${source_path}")")
  if [[ -z "${abs_source}" ]]; then
    mac_ops_log_error "경로 변환 실패: ${source_path}"
    return 1
  fi

  # 같은 볼륨인지 확인
  if ! mac_ops_is_same_volume "${abs_source}" "${MAC_OPS_TRASH_DIR}"; then
    mac_ops_log_error "다른 볼륨의 파일은 휴지통으로 이동할 수 없습니다: ${abs_source}"
    return 1
  fi

  # DRY_RUN 모드
  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] 휴지통 이동 예정: ${abs_source} (사유: ${reason})"
    return 0
  fi

  # 휴지통 내 대상 경로 (원래 경로 구조 유지)
  local trash_path="${MAC_OPS_TRASH_DIR}${abs_source}"
  local trash_parent
  trash_parent=$(dirname "${trash_path}")

  # 대상 디렉토리 생성
  if ! mkdir -p "${trash_parent}" 2>/dev/null; then
    mac_ops_log_error "휴지통 디렉토리 생성 실패: ${trash_parent}"
    return 1
  fi

  # 이미 같은 경로에 파일이 있으면 타임스탬프 접미사 추가
  if [[ -e "${trash_path}" ]]; then
    local ts_suffix
    ts_suffix=$(date '+%Y%m%d_%H%M%S')
    trash_path="${trash_path}.${ts_suffix}"
  fi

  # 파일 크기 계산
  local size_bytes
  size_bytes=$(mac_ops_get_dir_size "${abs_source}")

  # 타임스탬프
  local now_iso
  now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local expires_iso
  expires_iso=$(date -u -v+"${MAC_OPS_TRASH_RETENTION_HOURS}"H '+%Y-%m-%dT%H:%M:%SZ')

  # 메타데이터 파일명: 원본 경로의 sha256 해시 + 타임스탬프
  local path_hash
  path_hash=$(print -n "${abs_source}" | shasum -a 256 | cut -d' ' -f1)
  local meta_ts
  meta_ts=$(date '+%Y%m%d%H%M%S')
  local meta_file="${MAC_OPS_META_DIR}/${path_hash}_${meta_ts}.plist"

  # 1단계: 메타데이터를 in_progress 상태로 생성
  _mac_ops_create_metadata "${meta_file}" \
    "${abs_source}" "${trash_path}" "${now_iso}" "${expires_iso}" \
    "${size_bytes}" "${reason}" "${module_name}" "in_progress"

  if [[ $? -ne 0 ]]; then
    mac_ops_log_error "메타데이터 생성 실패: ${meta_file}"
    return 1
  fi

  # 2단계: 실제 이동
  if ! mv "${abs_source}" "${trash_path}" 2>/dev/null; then
    mac_ops_log_error "파일 이동 실패: ${abs_source} -> ${trash_path}"
    # 실패 시 메타데이터 삭제
    rm -f "${meta_file}"
    return 1
  fi

  # 3단계: 메타데이터를 completed 상태로 업데이트
  plutil -replace Status -string "completed" "${meta_file}" 2>/dev/null

  mac_ops_log_info "휴지통 이동 완료: ${abs_source} (${size_bytes} bytes, 사유: ${reason})"
  return 0
}

# -----------------------------------------------------------------------------
# 만료된 항목 영구 삭제
# .metadata/ 에서 ExpiresAt이 현재 시간 이전인 항목 처리
# -----------------------------------------------------------------------------
mac_ops_trash_expire() {
  local now_epoch
  now_epoch=$(date +%s)
  local deleted_count=0
  local freed_bytes=0
  local meta_status=""
  local expires_at=""
  local expires_epoch=""
  local trash_path=""
  local size_bytes=0

  # 메타데이터 파일 순회
  for meta_file in "${MAC_OPS_META_DIR}"/*.plist(N); do
    [[ ! -f "${meta_file}" ]] && continue

    # completed 상태만 처리
    meta_status=$(plutil -extract Status raw "${meta_file}" 2>/dev/null)
    [[ "${meta_status}" != "completed" ]] && continue

    # 만료 시간 확인
    expires_at=$(plutil -extract ExpiresAt raw "${meta_file}" 2>/dev/null)
    [[ -z "${expires_at}" ]] && continue

    # ISO8601 -> epoch 변환
    expires_epoch=$(date -jf '%Y-%m-%dT%H:%M:%SZ' "${expires_at}" '+%s' 2>/dev/null)
    [[ -z "${expires_epoch}" ]] && continue

    # 만료 여부 확인
    if [[ ${now_epoch} -ge ${expires_epoch} ]]; then
      trash_path=$(plutil -extract TrashPath raw "${meta_file}" 2>/dev/null)
      size_bytes=$(plutil -extract SizeBytes raw "${meta_file}" 2>/dev/null || echo 0)

      # 휴지통 파일 영구 삭제
      if [[ -n "${trash_path}" && -e "${trash_path}" ]]; then
        rm -rf "${trash_path}" 2>/dev/null
        freed_bytes=$((freed_bytes + size_bytes))
      fi

      # 메타데이터 삭제
      rm -f "${meta_file}"
      deleted_count=$((deleted_count + 1))
    fi
  done

  # 빈 디렉토리 정리
  find "${MAC_OPS_TRASH_DIR}" -type d -empty -delete 2>/dev/null

  local freed_mb=$((freed_bytes / 1048576))
  mac_ops_log_info "만료 처리 완료: ${deleted_count}개 항목 삭제, ${freed_mb}MB 확보"
  return 0
}

# -----------------------------------------------------------------------------
# 휴지통에서 원래 위치로 복원
# 사용법: mac_ops_trash_restore <원래경로>
# -----------------------------------------------------------------------------
mac_ops_trash_restore() {
  local original_path="${1}"

  if [[ -z "${original_path}" ]]; then
    mac_ops_log_error "사용법: mac_ops_trash_restore <원래경로>"
    return 1
  fi

  # 절대 경로로 변환 (존재하지 않는 경로일 수 있으므로 직접 처리)
  if [[ "${original_path}" != /* ]]; then
    original_path="${PWD}/${original_path}"
  fi

  # 원래 경로의 sha256로 메타데이터 검색
  local path_hash
  path_hash=$(print -n "${original_path}" | shasum -a 256 | cut -d' ' -f1)

  local found_meta=""
  local latest_ts=0
  local meta_status=""
  local meta_ts=""

  # 해당 해시로 시작하는 메타데이터 중 가장 최근 것 선택
  for meta_file in "${MAC_OPS_META_DIR}/${path_hash}"_*.plist(N); do
    [[ ! -f "${meta_file}" ]] && continue

    meta_status=$(plutil -extract Status raw "${meta_file}" 2>/dev/null)
    [[ "${meta_status}" != "completed" ]] && continue

    # 파일명에서 타임스탬프 추출하여 최신 것 선택
    meta_ts=$(basename "${meta_file}" .plist | sed "s/${path_hash}_//")
    if [[ ${meta_ts} -gt ${latest_ts} ]]; then
      latest_ts=${meta_ts}
      found_meta="${meta_file}"
    fi
  done

  if [[ -z "${found_meta}" ]]; then
    mac_ops_log_error "복원할 항목을 찾을 수 없습니다: ${original_path}"
    return 1
  fi

  local trash_path
  trash_path=$(plutil -extract TrashPath raw "${found_meta}" 2>/dev/null)

  if [[ -z "${trash_path}" || ! -e "${trash_path}" ]]; then
    mac_ops_log_error "휴지통 파일이 존재하지 않습니다: ${trash_path}"
    rm -f "${found_meta}"
    return 1
  fi

  # 원래 위치의 부모 디렉토리 생성
  local restore_parent
  restore_parent=$(dirname "${original_path}")
  if [[ ! -d "${restore_parent}" ]]; then
    mkdir -p "${restore_parent}" 2>/dev/null
  fi

  # 원래 위치에 이미 파일이 있으면 중단
  if [[ -e "${original_path}" ]]; then
    mac_ops_log_error "원래 위치에 이미 파일이 존재합니다: ${original_path}"
    return 1
  fi

  # 복원 실행
  if ! mv "${trash_path}" "${original_path}" 2>/dev/null; then
    mac_ops_log_error "복원 실패: ${trash_path} -> ${original_path}"
    return 1
  fi

  # 메타데이터 삭제
  rm -f "${found_meta}"

  # 빈 디렉토리 정리
  find "${MAC_OPS_TRASH_DIR}" -type d -empty -delete 2>/dev/null

  mac_ops_log_info "복원 완료: ${original_path}"
  return 0
}

# -----------------------------------------------------------------------------
# 휴지통 목록 출력
# 모든 메타데이터 읽어서 표 형태로 출력
# -----------------------------------------------------------------------------
mac_ops_trash_list() {
  local count=0
  local meta_status=""
  local orig=""
  local size=0
  local moved=""
  local expires=""
  local reason=""
  local human_size=""

  # 헤더 출력
  printf "%-50s %12s %-20s %-20s %s\n" \
    "원래경로" "크기" "이동일시" "만료일시" "사유"
  printf "%0.s-" {1..120}
  print ""

  for meta_file in "${MAC_OPS_META_DIR}"/*.plist(N); do
    [[ ! -f "${meta_file}" ]] && continue

    meta_status=$(plutil -extract Status raw "${meta_file}" 2>/dev/null)
    [[ "${meta_status}" != "completed" ]] && continue

    orig=$(plutil -extract OriginalPath raw "${meta_file}" 2>/dev/null)
    size=$(plutil -extract SizeBytes raw "${meta_file}" 2>/dev/null || echo 0)
    moved=$(plutil -extract MovedAt raw "${meta_file}" 2>/dev/null)
    expires=$(plutil -extract ExpiresAt raw "${meta_file}" 2>/dev/null)
    reason=$(plutil -extract Reason raw "${meta_file}" 2>/dev/null)

    # 크기를 사람이 읽을 수 있는 형태로 변환
    human_size=$(_mac_ops_human_size "${size}")

    printf "%-50s %12s %-20s %-20s %s\n" \
      "${orig}" "${human_size}" "${moved}" "${expires}" "${reason}"

    count=$((count + 1))
  done

  if [[ ${count} -eq 0 ]]; then
    mac_ops_log_info "휴지통이 비어있습니다"
  else
    print ""
    mac_ops_log_info "총 ${count}개 항목"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# 휴지통 상태 출력
# 총 크기, 항목 수, 가장 빠른 만료 시간
# -----------------------------------------------------------------------------
mac_ops_trash_status() {
  local total_bytes=0
  local item_count=0
  local earliest_expires=""
  local earliest_epoch=999999999999
  local meta_status=""
  local size=0
  local expires=""
  local exp_epoch=""

  for meta_file in "${MAC_OPS_META_DIR}"/*.plist(N); do
    [[ ! -f "${meta_file}" ]] && continue

    meta_status=$(plutil -extract Status raw "${meta_file}" 2>/dev/null)
    [[ "${meta_status}" != "completed" ]] && continue

    size=$(plutil -extract SizeBytes raw "${meta_file}" 2>/dev/null || echo 0)
    total_bytes=$((total_bytes + size))
    item_count=$((item_count + 1))

    expires=$(plutil -extract ExpiresAt raw "${meta_file}" 2>/dev/null)
    if [[ -n "${expires}" ]]; then
      exp_epoch=$(date -jf '%Y-%m-%dT%H:%M:%SZ' "${expires}" '+%s' 2>/dev/null)
      if [[ -n "${exp_epoch}" && ${exp_epoch} -lt ${earliest_epoch} ]]; then
        earliest_epoch=${exp_epoch}
        earliest_expires="${expires}"
      fi
    fi
  done

  local human_total
  human_total=$(_mac_ops_human_size "${total_bytes}")

  print "=== mac-ops 휴지통 상태 ==="
  print "총 항목 수: ${item_count}"
  print "총 크기:    ${human_total}"
  if [[ -n "${earliest_expires}" ]]; then
    print "다음 만료:  ${earliest_expires}"
  else
    print "다음 만료:  없음"
  fi

  return 0
}

# =============================================================================
# 내부 헬퍼 함수
# =============================================================================

# 메타데이터 plist 생성 (plutil 사용)
_mac_ops_create_metadata() {
  local meta_file="${1}"
  local original_path="${2}"
  local trash_path="${3}"
  local moved_at="${4}"
  local expires_at="${5}"
  local size_bytes="${6}"
  local reason="${7}"
  local module_name="${8}"
  local meta_status="${9}"

  # 빈 plist 생성
  plutil -create xml1 "${meta_file}" 2>/dev/null || return 1

  # 각 키 삽입
  plutil -insert OriginalPath -string "${original_path}" "${meta_file}" 2>/dev/null
  plutil -insert TrashPath    -string "${trash_path}"    "${meta_file}" 2>/dev/null
  plutil -insert MovedAt      -string "${moved_at}"      "${meta_file}" 2>/dev/null
  plutil -insert ExpiresAt    -string "${expires_at}"    "${meta_file}" 2>/dev/null
  plutil -insert SizeBytes    -integer "${size_bytes}"   "${meta_file}" 2>/dev/null
  plutil -insert Reason       -string "${reason}"        "${meta_file}" 2>/dev/null
  plutil -insert Module       -string "${module_name}"   "${meta_file}" 2>/dev/null
  plutil -insert Status       -string "${meta_status}"   "${meta_file}" 2>/dev/null

  return 0
}

# 바이트를 사람이 읽을 수 있는 단위로 변환
_mac_ops_human_size() {
  local bytes="${1:-0}"

  if [[ ${bytes} -ge 1073741824 ]]; then
    printf "%.1fGB" "$((bytes * 10 / 1073741824))e-1"
  elif [[ ${bytes} -ge 1048576 ]]; then
    printf "%.1fMB" "$((bytes * 10 / 1048576))e-1"
  elif [[ ${bytes} -ge 1024 ]]; then
    printf "%.1fKB" "$((bytes * 10 / 1024))e-1"
  else
    printf "%dB" "${bytes}"
  fi
}
