# =============================================================================
# mac-ops: 안전 시스템
# 화이트리스트, 보호 프로세스, 크기 가드, SIP 체크
# =============================================================================

# --- 절대 건드리지 않는 경로 배열 ---
MAC_OPS_WHITELIST=(
  "/System"
  "/bin"
  "/sbin"
  "/usr"
  "/Applications/App Store.app"
  "/Applications/Automator.app"
  "/Applications/Calculator.app"
  "/Applications/Calendar.app"
  "/Applications/Chess.app"
  "/Applications/Contacts.app"
  "/Applications/Dashboard.app"
  "/Applications/Dictionary.app"
  "/Applications/FaceTime.app"
  "/Applications/Finder.app"
  "/Applications/Font Book.app"
  "/Applications/Home.app"
  "/Applications/Image Capture.app"
  "/Applications/Launchpad.app"
  "/Applications/Mail.app"
  "/Applications/Maps.app"
  "/Applications/Messages.app"
  "/Applications/Migration Assistant.app"
  "/Applications/Music.app"
  "/Applications/News.app"
  "/Applications/Notes.app"
  "/Applications/Photo Booth.app"
  "/Applications/Photos.app"
  "/Applications/Podcasts.app"
  "/Applications/Preview.app"
  "/Applications/QuickTime Player.app"
  "/Applications/Reminders.app"
  "/Applications/Safari.app"
  "/Applications/Shortcuts.app"
  "/Applications/Siri.app"
  "/Applications/Stickies.app"
  "/Applications/Stocks.app"
  "/Applications/System Preferences.app"
  "/Applications/System Settings.app"
  "/Applications/TV.app"
  "/Applications/TextEdit.app"
  "/Applications/Time Machine.app"
  "/Applications/Utilities"
  "${HOME}/Library/Keychains"
  "${HOME}/Library/Preferences"
  "${HOME}/Documents"
  "${HOME}/Desktop"
  "${HOME}/Downloads"
  "/Library/LaunchDaemons"
  "/Library/LaunchAgents"
)

# --- 절대 종료하지 않는 프로세스 배열 ---
MAC_OPS_PROTECTED_PROCESSES=(
  "kernel_task"
  "launchd"
  "WindowServer"
  "loginwindow"
  "SystemUIServer"
  "Finder"
  "cfprefsd"
  "mds"
  "mds_stores"
  "Dock"
  "coreaudiod"
  "opendirectoryd"
)

# --- 크기 제한 ---
MAC_OPS_MAX_SINGLE_FILE_BYTES=2147483648   # 2GB
MAC_OPS_MAX_BATCH_BYTES=10737418240        # 10GB

# -----------------------------------------------------------------------------
# 경로 안전성 체크
# 화이트리스트에 해당하면 위험(1), 아니면 안전(0)
# 사용법: mac_ops_is_path_safe <경로>
# -----------------------------------------------------------------------------
mac_ops_is_path_safe() {
  local target_path="${1}"

  if [[ -z "${target_path}" ]]; then
    mac_ops_log_error "경로가 지정되지 않았습니다"
    return 1
  fi

  # 절대 경로로 정규화
  local resolved_path
  if [[ -e "${target_path}" ]]; then
    # realpath가 있으면 사용, 없으면 수동 해석
    resolved_path=$(realpath "${target_path}" 2>/dev/null)
    if [[ -z "${resolved_path}" ]]; then
      resolved_path=$(cd "$(dirname "${target_path}")" 2>/dev/null && print -- "${PWD}/$(basename "${target_path}")")
    fi
  else
    # 존재하지 않는 경로는 그대로 사용
    resolved_path="${target_path}"
  fi

  # 이중 슬래시 제거 (루트 하위 경로 정규화)
  resolved_path="${resolved_path//\/\///}"

  # 화이트리스트 순회
  for protected in "${MAC_OPS_WHITELIST[@]}"; do
    # 정확히 일치하거나 하위 경로인 경우
    if [[ "${resolved_path}" == "${protected}" || "${resolved_path}" == "${protected}/"* ]]; then
      mac_ops_log_warn "보호된 경로입니다: ${resolved_path} (규칙: ${protected})"
      return 1
    fi
  done

  # 루트 디렉토리 자체 보호
  if [[ "${resolved_path}" == "/" ]]; then
    mac_ops_log_warn "루트 디렉토리는 보호됩니다"
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# 보호 프로세스 체크
# 보호 프로세스이면 1, 아니면 0
# 사용법: mac_ops_is_process_protected <프로세스명>
# -----------------------------------------------------------------------------
mac_ops_is_process_protected() {
  local process_name="${1}"

  if [[ -z "${process_name}" ]]; then
    mac_ops_log_error "프로세스명이 지정되지 않았습니다"
    return 1
  fi

  for protected in "${MAC_OPS_PROTECTED_PROCESSES[@]}"; do
    if [[ "${process_name}" == "${protected}" ]]; then
      mac_ops_log_warn "보호된 프로세스입니다: ${process_name}"
      return 1
    fi
  done

  return 0
}

# -----------------------------------------------------------------------------
# 크기 가드 체크
# 2GB 초과 파일이면 1 반환 (--force / MAC_OPS_FORCE=true면 무시)
# 사용법: mac_ops_check_size_guard <경로>
# -----------------------------------------------------------------------------
mac_ops_check_size_guard() {
  local target_path="${1}"

  if [[ -z "${target_path}" || ! -e "${target_path}" ]]; then
    mac_ops_log_error "존재하지 않는 경로입니다: ${target_path}"
    return 1
  fi

  local size_bytes
  size_bytes=$(mac_ops_get_dir_size "${target_path}")

  if [[ ${size_bytes} -gt ${MAC_OPS_MAX_SINGLE_FILE_BYTES} ]]; then
    if [[ "${MAC_OPS_FORCE}" == "true" ]]; then
      mac_ops_log_warn "크기 가드 초과 (${size_bytes} bytes)이지만 --force 모드로 계속합니다: ${target_path}"
      return 0
    fi
    local size_gb=$(( size_bytes / 1073741824 ))
    mac_ops_log_error "크기 가드: ${target_path} (${size_gb}GB)가 2GB 제한을 초과합니다. --force로 무시할 수 있습니다."
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# SIP(System Integrity Protection) 보호 경로 체크
# SIP 보호 경로이면 1, 아니면 0
# 사용법: mac_ops_check_sip <경로>
# -----------------------------------------------------------------------------
mac_ops_check_sip() {
  local target_path="${1}"

  if [[ -z "${target_path}" ]]; then
    mac_ops_log_error "경로가 지정되지 않았습니다"
    return 1
  fi

  # SIP 보호 경로 목록
  local sip_paths=(
    "/System"
    "/usr"
    "/bin"
    "/sbin"
    "/var"
    "/Applications/Utilities"
  )

  # /usr/local은 SIP 보호 대상이 아님
  if [[ "${target_path}" == "/usr/local"* ]]; then
    return 0
  fi

  for sip_path in "${sip_paths[@]}"; do
    if [[ "${target_path}" == "${sip_path}" || "${target_path}" == "${sip_path}/"* ]]; then
      mac_ops_log_error "SIP 보호 경로입니다: ${target_path}"
      return 1
    fi
  done

  return 0
}
