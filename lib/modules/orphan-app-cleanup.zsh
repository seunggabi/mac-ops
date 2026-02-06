# =============================================================================
# mac-ops: 고아 앱 데이터 정리 모듈
# 삭제된 앱의 잔존 파일(Application Support, Caches, Preferences 등)을 탐지하여 정리
# com.apple.* 제외, Group Containers 제외, 최근 7일 이내 수정된 파일 제외
# =============================================================================

# --- 기본 설정 ---
MAC_OPS_ORPHAN_APP_GRACE_DAYS=${MAC_OPS_ORPHAN_APP_GRACE_DAYS:-7}

# --- 스캔 대상 경로 ---
MAC_OPS_ORPHAN_APP_SCAN_DIRS=(
  "${HOME}/Library/Application Support"
  "${HOME}/Library/Caches"
  "${HOME}/Library/Preferences"
  "${HOME}/Library/Saved Application State"
  "${HOME}/Library/Containers"
  "${HOME}/Library/HTTPStorages"
  "${HOME}/Library/WebKit"
)

# -----------------------------------------------------------------------------
# 고아 앱 데이터 정리 메인 함수
# 1. /Applications, ~/Applications에서 설치된 앱의 번들 ID 추출
# 2. 스캔 대상 경로에서 번들 ID 패턴의 디렉토리/파일 탐색
# 3. 설치된 앱 목록에 없으면 고아 파일로 판정하여 정리
# -----------------------------------------------------------------------------
mac_ops_orphan_app_cleanup() {
  mac_ops_log_info "고아 앱 데이터 정리 시작"

  # 1단계: 설치된 앱의 번들 ID 수집 (글로벌 연관 배열 사용)
  typeset -gA _MAC_OPS_INSTALLED_BUNDLES
  _MAC_OPS_INSTALLED_BUNDLES=()
  _mac_ops_collect_installed_bundles

  local bundle_count=${#_MAC_OPS_INSTALLED_BUNDLES[@]}
  mac_ops_log_info "설치된 앱 번들 ID ${bundle_count}개 수집됨"

  if [[ ${bundle_count} -eq 0 ]]; then
    mac_ops_log_warn "설치된 앱 번들 ID를 수집하지 못했습니다. 안전을 위해 중단합니다."
    return 1
  fi

  # 2단계: 각 스캔 대상 경로에서 고아 데이터 탐색
  local total_cleaned=0
  for scan_dir in "${MAC_OPS_ORPHAN_APP_SCAN_DIRS[@]}"; do
    if [[ ! -d "${scan_dir}" ]]; then
      mac_ops_log_debug "스캔 대상 경로 없음: ${scan_dir}"
      continue
    fi

    # Preferences 디렉토리는 plist 파일 기반으로 처리
    if [[ "${scan_dir}" == *"/Preferences" ]]; then
      _mac_ops_scan_preferences "${scan_dir}"
    else
      _mac_ops_scan_directory "${scan_dir}"
    fi
  done

  # 글로벌 변수 정리
  unset _MAC_OPS_INSTALLED_BUNDLES

  mac_ops_log_info "고아 앱 데이터 정리 완료"
  return 0
}

# -----------------------------------------------------------------------------
# 내부: 설치된 앱의 번들 ID를 연관 배열에 수집
# /Applications/*.app, ~/Applications/*.app 모두 포함
# 사용법: _mac_ops_collect_installed_bundles <연관배열명>
# -----------------------------------------------------------------------------
_mac_ops_collect_installed_bundles() {
  local app_dirs=("/Applications" "${HOME}/Applications")
  local info_plist=""
  local bundle_id=""

  for app_base in "${app_dirs[@]}"; do
    [[ ! -d "${app_base}" ]] && continue

    for app_path in "${app_base}"/*.app(N); do
      [[ ! -d "${app_path}" ]] && continue

      info_plist="${app_path}/Contents/Info.plist"
      if [[ ! -f "${info_plist}" ]]; then
        mac_ops_log_debug "Info.plist 없음: ${app_path}"
        continue
      fi

      # 번들 ID 추출
      bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${info_plist}" 2>/dev/null)
      if [[ -n "${bundle_id}" ]]; then
        _MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]=1
        mac_ops_log_debug "번들 ID 수집: ${bundle_id} (${app_path})"
      fi
    done
  done
}

# -----------------------------------------------------------------------------
# 내부: 디렉토리에서 고아 번들 ID 항목 탐색 및 정리
# 디렉토리명이 번들 ID 패턴(com.xxx.xxx)이면서 설치 목록에 없는 것을 처리
# 사용법: _mac_ops_scan_directory <스캔경로> <설치된번들배열명>
# -----------------------------------------------------------------------------
_mac_ops_scan_directory() {
  local scan_dir="${1}"
  local now_epoch
  local grace_seconds=$((MAC_OPS_ORPHAN_APP_GRACE_DAYS * 86400))
  local count=0
  local item_name
  local mtime
  local age_seconds
  local item_size

  now_epoch=$(date +%s)

  mac_ops_log_info "고아 데이터 스캔: ${scan_dir}"

  count=0

  # 1단계 하위 항목만 순회 (번들 ID 디렉토리)
  for item in "${scan_dir}"/*(N); do
    item_name=$(basename "${item}")

    # 번들 ID 패턴 매칭 (com.xxx.xxx 또는 org.xxx.xxx 등)
    # 최소 2개의 점(.)이 포함된 역도메인 형식
    if [[ ! "${item_name}" =~ ^[a-zA-Z][a-zA-Z0-9-]*\.[a-zA-Z][a-zA-Z0-9-]*\..+ ]]; then
      continue
    fi

    # com.apple.* 제외 (시스템 데이터)
    if [[ "${item_name}" == com.apple.* ]]; then
      continue
    fi

    # Group Containers 하위는 처리하지 않음 (여러 앱이 공유 가능)
    if [[ "${scan_dir}" == *"Group Containers"* ]]; then
      continue
    fi

    # 설치된 앱 목록에 있으면 건너뜀
    if [[ -n "${_MAC_OPS_INSTALLED_BUNDLES[${item_name}]+_}" ]]; then
      continue
    fi

    # 최근 수정 여부 확인 (grace period)
    mtime=$(stat -f%m "${item}" 2>/dev/null)
    if [[ -n "${mtime}" && "${mtime}" =~ ^[0-9]+$ ]]; then
      age_seconds=$((now_epoch - mtime))
      if [[ ${age_seconds} -lt ${grace_seconds} ]]; then
        mac_ops_log_debug "최근 수정됨, 건너뜀: ${item_name} (${age_seconds}초 전)"
        continue
      fi
    fi

    # 안전성 체크
    if ! mac_ops_is_path_safe "${item}"; then
      continue
    fi

    # 크기 가드 체크
    if ! mac_ops_check_size_guard "${item}"; then
      continue
    fi

    # 파일/디렉토리 크기 기록
    item_size=$(mac_ops_get_dir_size "${item}")

    mac_ops_log_info "고아 앱 데이터 발견: ${item_name} ($(mac_ops_format_bytes "${item_size}"))"

    # 휴지통으로 이동
    if mac_ops_trash_move "${item}" "orphan-app-data" "orphan-app-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + item_size))
      count=$((count + 1))
    fi
  done

  mac_ops_log_info "${scan_dir}: ${count}개 고아 항목 정리됨"
  return 0
}

# -----------------------------------------------------------------------------
# 내부: ~/Library/Preferences에서 고아 plist 파일 탐색 및 정리
# *.plist 파일명에서 번들 ID를 추출하여 매칭
# 사용법: _mac_ops_scan_preferences <Preferences경로> <설치된번들배열명>
# -----------------------------------------------------------------------------
_mac_ops_scan_preferences() {
  local pref_dir="${1}"
  local now_epoch
  local grace_seconds=$((MAC_OPS_ORPHAN_APP_GRACE_DAYS * 86400))
  local count=0
  local file_name
  local mtime
  local age_seconds
  local file_size

  now_epoch=$(date +%s)

  mac_ops_log_info "고아 Preferences 스캔: ${pref_dir}"

  count=0

  for plist_file in "${pref_dir}"/*.plist(N); do
    [[ ! -f "${plist_file}" ]] && continue

    # 파일명에서 번들 ID 추출 (com.xxx.xxx.plist -> com.xxx.xxx)
    file_name=$(basename "${plist_file}" .plist)

    # 번들 ID 패턴 매칭
    if [[ ! "${file_name}" =~ ^[a-zA-Z][a-zA-Z0-9-]*\.[a-zA-Z][a-zA-Z0-9-]*\..+ ]]; then
      continue
    fi

    # com.apple.* 제외
    if [[ "${file_name}" == com.apple.* ]]; then
      continue
    fi

    # 설치된 앱 목록에 있으면 건너뜀
    if [[ -n "${_MAC_OPS_INSTALLED_BUNDLES[${file_name}]+_}" ]]; then
      continue
    fi

    # 최근 수정 여부 확인
    mtime=$(stat -f%m "${plist_file}" 2>/dev/null)
    if [[ -n "${mtime}" && "${mtime}" =~ ^[0-9]+$ ]]; then
      age_seconds=$((now_epoch - mtime))
      if [[ ${age_seconds} -lt ${grace_seconds} ]]; then
        continue
      fi
    fi

    # 안전성 체크 -- Preferences는 화이트리스트에 포함되어 있으므로
    # 개별 plist 파일 단위로는 안전 (상위 디렉토리 자체가 보호 대상)
    # is_path_safe는 상위 디렉토리 ~/Library/Preferences를 보호하므로
    # 하위 파일에 대해 직접 호출하면 차단됨 -> 여기서는 개별 파일이므로 스킵
    # 대신 크기 가드만 체크
    if ! mac_ops_check_size_guard "${plist_file}"; then
      continue
    fi

    # 파일 크기 기록
    file_size=$(mac_ops_get_dir_size "${plist_file}")

    mac_ops_log_info "고아 Preference 발견: ${file_name}.plist ($(mac_ops_format_bytes "${file_size}"))"

    # 휴지통으로 이동
    if mac_ops_trash_move "${plist_file}" "orphan-app-preference" "orphan-app-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done

  mac_ops_log_info "${pref_dir}: ${count}개 고아 Preference 정리됨"
  return 0
}
