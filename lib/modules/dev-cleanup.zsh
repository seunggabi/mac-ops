# =============================================================================
# mac-ops: 개발도구 캐시 정리 모듈
# Xcode, npm, yarn, pnpm, pip, gradle, CocoaPods 등 개발도구 캐시 통합 정리
# =============================================================================

# -----------------------------------------------------------------------------
# Xcode 캐시 정리
# DerivedData, Archives, CoreSimulator 캐시
# -----------------------------------------------------------------------------
_mac_ops_dev_xcode() {
  local xcode_derived="${HOME}/Library/Developer/Xcode/DerivedData"
  local xcode_archives="${HOME}/Library/Developer/Xcode/Archives"
  local xcode_simulator="${HOME}/Library/Developer/CoreSimulator/Caches"

  local has_xcode=false

  # Xcode 관련 디렉토리 중 하나라도 있으면 설치된 것으로 간주
  if [[ -d "${xcode_derived}" || -d "${xcode_archives}" || -d "${xcode_simulator}" ]]; then
    has_xcode=true
  fi

  if [[ "${has_xcode}" == "false" ]]; then
    mac_ops_log_debug "Xcode가 설치되지 않았습니다. 건너뜁니다."
    return 0
  fi

  mac_ops_log_info "Xcode 캐시 정리 중..."

  # DerivedData 전체 정리
  if [[ -d "${xcode_derived}" ]]; then
    local derived_size
    derived_size=$(mac_ops_get_dir_size "${xcode_derived}")

    if [[ ${derived_size} -gt 0 ]]; then
      if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
        mac_ops_log_info "[DRY_RUN] 정리 예정: ${xcode_derived} ($(mac_ops_format_bytes ${derived_size}))"
      else
        # DerivedData 내 모든 항목을 trash로 이동
        for item in "${xcode_derived}"/*; do
          [[ ! -e "${item}" ]] && continue
          mac_ops_trash_move "${item}" "Xcode DerivedData 정리" "dev-cleanup"
        done

        MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + derived_size))
        MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
        mac_ops_log_info "Xcode DerivedData 정리 완료: $(mac_ops_format_bytes ${derived_size})"
      fi
    fi
  fi

  # Archives 중 90일 이상 된 것 정리
  if [[ -d "${xcode_archives}" ]]; then
    local now_epoch
    local ninety_days_ago
    local archive_count=0
    local archive_size=0
    local archive_time
    local item_size

    now_epoch=$(date +%s)
    ninety_days_ago=$((now_epoch - 7776000))  # 90일 = 7776000초

    for archive in "${xcode_archives}"/*; do
      [[ ! -d "${archive}" ]] && continue

      archive_time=$(stat -f%m "${archive}" 2>/dev/null || echo 0)

      if [[ ${archive_time} -lt ${ninety_days_ago} ]]; then
        item_size=$(mac_ops_get_dir_size "${archive}")
        archive_size=$((archive_size + item_size))
        archive_count=$((archive_count + 1))

        if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
          mac_ops_log_info "[DRY_RUN] 정리 예정: ${archive} ($(mac_ops_format_bytes ${item_size}))"
        else
          mac_ops_trash_move "${archive}" "90일 이상 된 Xcode Archive" "dev-cleanup"
        fi
      fi
    done

    if [[ ${archive_count} -gt 0 && "${MAC_OPS_DRY_RUN}" != "true" ]]; then
      MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + archive_size))
      MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + archive_count))
      mac_ops_log_info "Xcode Archives 정리 완료: ${archive_count}개, $(mac_ops_format_bytes ${archive_size})"
    fi
  fi

  # CoreSimulator Caches 정리
  if [[ -d "${xcode_simulator}" ]]; then
    local sim_size
    sim_size=$(mac_ops_get_dir_size "${xcode_simulator}")

    if [[ ${sim_size} -gt 0 ]]; then
      if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
        mac_ops_log_info "[DRY_RUN] 정리 예정: ${xcode_simulator} ($(mac_ops_format_bytes ${sim_size}))"
      else
        for item in "${xcode_simulator}"/*; do
          [[ ! -e "${item}" ]] && continue
          mac_ops_trash_move "${item}" "Xcode Simulator 캐시 정리" "dev-cleanup"
        done

        MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + sim_size))
        MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
        mac_ops_log_info "Xcode Simulator 캐시 정리 완료: $(mac_ops_format_bytes ${sim_size})"
      fi
    fi
  fi

  return 0
}

# -----------------------------------------------------------------------------
# npm 캐시 정리
# ~/.npm/_cacache 전체
# -----------------------------------------------------------------------------
_mac_ops_dev_npm() {
  if ! command -v npm &>/dev/null; then
    mac_ops_log_debug "npm이 설치되지 않았습니다. 건너뜁니다."
    return 0
  fi

  local npm_cache="${HOME}/.npm/_cacache"

  if [[ ! -d "${npm_cache}" ]]; then
    mac_ops_log_debug "npm 캐시 디렉토리가 없습니다."
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${npm_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] npm 캐시 정리 예정: ${npm_cache} ($(mac_ops_format_bytes ${cache_size}))"
    return 0
  fi

  mac_ops_log_info "npm 캐시 정리 중..."

  for item in "${npm_cache}"/*; do
    [[ ! -e "${item}" ]] && continue
    mac_ops_trash_move "${item}" "npm 캐시 정리" "dev-cleanup"
  done

  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + cache_size))
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
  mac_ops_log_info "npm 캐시 정리 완료: $(mac_ops_format_bytes ${cache_size})"

  return 0
}

# -----------------------------------------------------------------------------
# yarn 캐시 정리
# ~/.yarn/cache 전체
# -----------------------------------------------------------------------------
_mac_ops_dev_yarn() {
  if ! command -v yarn &>/dev/null; then
    mac_ops_log_debug "yarn이 설치되지 않았습니다. 건너뜁니다."
    return 0
  fi

  local yarn_cache="${HOME}/.yarn/cache"

  if [[ ! -d "${yarn_cache}" ]]; then
    mac_ops_log_debug "yarn 캐시 디렉토리가 없습니다."
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${yarn_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] yarn 캐시 정리 예정: ${yarn_cache} ($(mac_ops_format_bytes ${cache_size}))"
    return 0
  fi

  mac_ops_log_info "yarn 캐시 정리 중..."

  for item in "${yarn_cache}"/*; do
    [[ ! -e "${item}" ]] && continue
    mac_ops_trash_move "${item}" "yarn 캐시 정리" "dev-cleanup"
  done

  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + cache_size))
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
  mac_ops_log_info "yarn 캐시 정리 완료: $(mac_ops_format_bytes ${cache_size})"

  return 0
}

# -----------------------------------------------------------------------------
# pnpm 캐시 정리
# ~/.pnpm-store 전체
# -----------------------------------------------------------------------------
_mac_ops_dev_pnpm() {
  if ! command -v pnpm &>/dev/null; then
    mac_ops_log_debug "pnpm이 설치되지 않았습니다. 건너뜁니다."
    return 0
  fi

  local pnpm_store="${HOME}/.pnpm-store"

  if [[ ! -d "${pnpm_store}" ]]; then
    mac_ops_log_debug "pnpm store 디렉토리가 없습니다."
    return 0
  fi

  local store_size
  store_size=$(mac_ops_get_dir_size "${pnpm_store}")

  if [[ ${store_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] pnpm store 정리 예정: ${pnpm_store} ($(mac_ops_format_bytes ${store_size}))"
    return 0
  fi

  mac_ops_log_info "pnpm store 정리 중..."

  for item in "${pnpm_store}"/*; do
    [[ ! -e "${item}" ]] && continue
    mac_ops_trash_move "${item}" "pnpm store 정리" "dev-cleanup"
  done

  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + store_size))
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
  mac_ops_log_info "pnpm store 정리 완료: $(mac_ops_format_bytes ${store_size})"

  return 0
}

# -----------------------------------------------------------------------------
# pip 캐시 정리
# ~/.cache/pip 전체
# -----------------------------------------------------------------------------
_mac_ops_dev_pip() {
  if ! command -v pip &>/dev/null && ! command -v pip3 &>/dev/null; then
    mac_ops_log_debug "pip이 설치되지 않았습니다. 건너뜁니다."
    return 0
  fi

  local pip_cache="${HOME}/.cache/pip"

  if [[ ! -d "${pip_cache}" ]]; then
    mac_ops_log_debug "pip 캐시 디렉토리가 없습니다."
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${pip_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] pip 캐시 정리 예정: ${pip_cache} ($(mac_ops_format_bytes ${cache_size}))"
    return 0
  fi

  mac_ops_log_info "pip 캐시 정리 중..."

  for item in "${pip_cache}"/*; do
    [[ ! -e "${item}" ]] && continue
    mac_ops_trash_move "${item}" "pip 캐시 정리" "dev-cleanup"
  done

  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + cache_size))
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
  mac_ops_log_info "pip 캐시 정리 완료: $(mac_ops_format_bytes ${cache_size})"

  return 0
}

# -----------------------------------------------------------------------------
# gradle 캐시 정리
# ~/.gradle/caches 전체
# -----------------------------------------------------------------------------
_mac_ops_dev_gradle() {
  if ! command -v gradle &>/dev/null; then
    mac_ops_log_debug "gradle이 설치되지 않았습니다. 건너뜁니다."
    return 0
  fi

  local gradle_cache="${HOME}/.gradle/caches"

  if [[ ! -d "${gradle_cache}" ]]; then
    mac_ops_log_debug "gradle 캐시 디렉토리가 없습니다."
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${gradle_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] gradle 캐시 정리 예정: ${gradle_cache} ($(mac_ops_format_bytes ${cache_size}))"
    return 0
  fi

  mac_ops_log_info "gradle 캐시 정리 중..."

  for item in "${gradle_cache}"/*; do
    [[ ! -e "${item}" ]] && continue
    mac_ops_trash_move "${item}" "gradle 캐시 정리" "dev-cleanup"
  done

  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + cache_size))
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
  mac_ops_log_info "gradle 캐시 정리 완료: $(mac_ops_format_bytes ${cache_size})"

  return 0
}

# -----------------------------------------------------------------------------
# CocoaPods 캐시 정리
# ~/Library/Caches/CocoaPods 전체
# -----------------------------------------------------------------------------
_mac_ops_dev_cocoapods() {
  if ! command -v pod &>/dev/null; then
    mac_ops_log_debug "CocoaPods가 설치되지 않았습니다. 건너뜁니다."
    return 0
  fi

  local pod_cache="${HOME}/Library/Caches/CocoaPods"

  if [[ ! -d "${pod_cache}" ]]; then
    mac_ops_log_debug "CocoaPods 캐시 디렉토리가 없습니다."
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${pod_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] CocoaPods 캐시 정리 예정: ${pod_cache} ($(mac_ops_format_bytes ${cache_size}))"
    return 0
  fi

  mac_ops_log_info "CocoaPods 캐시 정리 중..."

  for item in "${pod_cache}"/*; do
    [[ ! -e "${item}" ]] && continue
    mac_ops_trash_move "${item}" "CocoaPods 캐시 정리" "dev-cleanup"
  done

  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + cache_size))
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
  mac_ops_log_info "CocoaPods 캐시 정리 완료: $(mac_ops_format_bytes ${cache_size})"

  return 0
}

# -----------------------------------------------------------------------------
# 개발도구 통합 정리 메인 함수
# 모든 서브함수를 순차 호출
# -----------------------------------------------------------------------------
mac_ops_dev_cleanup() {
  mac_ops_log_info "개발도구 캐시 정리를 시작합니다..."

  # 각 개발도구별 정리 실행
  _mac_ops_dev_xcode
  _mac_ops_dev_npm
  _mac_ops_dev_yarn
  _mac_ops_dev_pnpm
  _mac_ops_dev_pip
  _mac_ops_dev_gradle
  _mac_ops_dev_cocoapods

  mac_ops_log_info "개발도구 캐시 정리 완료"
  return 0
}
