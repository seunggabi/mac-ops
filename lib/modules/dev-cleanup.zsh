# =============================================================================
# mac-ops: Developer tools cache cleanup module
# Integrated cleanup for Xcode, npm, yarn, pnpm, pip, gradle, CocoaPods, etc.
# =============================================================================

# --- Default settings ---
# Only delete cache items older than this many days (prevents wiping active caches)
MAC_OPS_DEV_CACHE_MAX_AGE_DAYS=${MAC_OPS_DEV_CACHE_MAX_AGE_DAYS:-30}

# -----------------------------------------------------------------------------
# Xcode cache cleanup
# DerivedData, Archives, CoreSimulator cache
# -----------------------------------------------------------------------------
_mac_ops_dev_xcode() {
  local xcode_derived="${HOME}/Library/Developer/Xcode/DerivedData"
  local xcode_archives="${HOME}/Library/Developer/Xcode/Archives"
  local xcode_simulator="${HOME}/Library/Developer/CoreSimulator/Caches"

  local has_xcode=false

  # Consider Xcode installed if any related directory exists
  if [[ -d "${xcode_derived}" || -d "${xcode_archives}" || -d "${xcode_simulator}" ]]; then
    has_xcode=true
  fi

  if [[ "${has_xcode}" == "false" ]]; then
    mac_ops_log_debug "Xcode is not installed. Skipping."
    return 0
  fi

  mac_ops_log_info "Cleaning Xcode cache..."

  # Clean all DerivedData
  if [[ -d "${xcode_derived}" ]]; then
    local derived_size
    derived_size=$(mac_ops_get_dir_size "${xcode_derived}")

    if [[ ${derived_size} -gt 0 ]]; then
      if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
        mac_ops_log_info "[DRY_RUN] Will clean: ${xcode_derived} ($(mac_ops_format_bytes ${derived_size}))"
      else
        # Move all items in DerivedData to trash
        for item in "${xcode_derived}"/*; do
          [[ ! -e "${item}" ]] && continue
          mac_ops_trash_move "${item}" "Xcode DerivedData cleanup" "dev-cleanup"
        done

        MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + derived_size))
        MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
        mac_ops_log_info "Xcode DerivedData cleanup completed: $(mac_ops_format_bytes ${derived_size})"
      fi
    fi
  fi

  # Clean Archives older than 90 days
  if [[ -d "${xcode_archives}" ]]; then
    local now_epoch
    local ninety_days_ago
    local archive_count=0
    local archive_size=0
    local archive_time
    local item_size

    now_epoch=$(date +%s)
    ninety_days_ago=$((now_epoch - 7776000))  # 90 days = 7776000 seconds

    for archive in "${xcode_archives}"/*; do
      [[ ! -d "${archive}" ]] && continue

      archive_time=$(stat -f%m "${archive}" 2>/dev/null || echo 0)

      if [[ ${archive_time} -lt ${ninety_days_ago} ]]; then
        item_size=$(mac_ops_get_dir_size "${archive}")
        archive_size=$((archive_size + item_size))
        archive_count=$((archive_count + 1))

        if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
          mac_ops_log_info "[DRY_RUN] Will clean: ${archive} ($(mac_ops_format_bytes ${item_size}))"
        else
          mac_ops_trash_move "${archive}" "Xcode Archive older than 90 days" "dev-cleanup"
        fi
      fi
    done

    if [[ ${archive_count} -gt 0 && "${MAC_OPS_DRY_RUN}" != "true" ]]; then
      MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + archive_size))
      MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + archive_count))
      mac_ops_log_info "Xcode Archives cleanup completed: ${archive_count} items, $(mac_ops_format_bytes ${archive_size})"
    fi
  fi

  # CoreSimulator Caches cleanup
  if [[ -d "${xcode_simulator}" ]]; then
    local sim_size
    sim_size=$(mac_ops_get_dir_size "${xcode_simulator}")

    if [[ ${sim_size} -gt 0 ]]; then
      if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
        mac_ops_log_info "[DRY_RUN] Will clean: ${xcode_simulator} ($(mac_ops_format_bytes ${sim_size}))"
      else
        for item in "${xcode_simulator}"/*; do
          [[ ! -e "${item}" ]] && continue
          mac_ops_trash_move "${item}" "Xcode Simulator cache cleanup" "dev-cleanup"
        done

        MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + sim_size))
        MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
        mac_ops_log_info "Xcode Simulator cache cleanup completed: $(mac_ops_format_bytes ${sim_size})"
      fi
    fi
  fi

  return 0
}

# -----------------------------------------------------------------------------
# npm cache cleanup
# ~/.npm/_cacache all
# -----------------------------------------------------------------------------
_mac_ops_dev_npm() {
  if ! command -v npm &>/dev/null; then
    mac_ops_log_debug "npm is not installed. Skipping."
    return 0
  fi

  local npm_cache="${HOME}/.npm/_cacache"

  if [[ ! -d "${npm_cache}" ]]; then
    mac_ops_log_debug "npm cache directory does not exist."
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${npm_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will clean npm cache: ${npm_cache} ($(mac_ops_format_bytes ${cache_size}))"
    return 0
  fi

  mac_ops_log_info "Cleaning npm cache..."

  local _dev_now _dev_max_age_s _dev_cleaned=0
  _dev_now=$(date +%s)
  _dev_max_age_s=$((MAC_OPS_DEV_CACHE_MAX_AGE_DAYS * 86400))

  for item in "${npm_cache}"/*; do
    [[ ! -e "${item}" ]] && continue
    local _dev_mtime _dev_sz
    _dev_mtime=$(stat -f%m "${item}" 2>/dev/null || echo 0)
    if [[ $((_dev_now - _dev_mtime)) -lt ${_dev_max_age_s} ]]; then
      mac_ops_log_debug "Skipping recent npm cache: $(basename ${item})"
      continue
    fi
    if mac_ops_ignore_check_path "${item}"; then
      mac_ops_log_debug "User ignore (path): ${item}"
      continue
    fi
    _dev_sz=$(mac_ops_get_dir_size "${item}")
    if mac_ops_trash_move "${item}" "npm cache cleanup" "dev-cleanup"; then
      _dev_cleaned=$((_dev_cleaned + _dev_sz))
    fi
  done

  if [[ ${_dev_cleaned} -gt 0 ]]; then
    MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + _dev_cleaned))
    MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
    mac_ops_log_info "npm cache cleanup completed: $(mac_ops_format_bytes ${_dev_cleaned})"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# yarn cache cleanup
# ~/.yarn/cache all
# -----------------------------------------------------------------------------
_mac_ops_dev_yarn() {
  if ! command -v yarn &>/dev/null; then
    mac_ops_log_debug "yarn is not installed. Skipping."
    return 0
  fi

  local yarn_cache="${HOME}/.yarn/cache"

  if [[ ! -d "${yarn_cache}" ]]; then
    mac_ops_log_debug "yarn cache directory does not exist."
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${yarn_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will clean yarn cache: ${yarn_cache} ($(mac_ops_format_bytes ${cache_size}))"
    return 0
  fi

  mac_ops_log_info "Cleaning yarn cache..."

  local _dev_now _dev_max_age_s _dev_cleaned=0
  _dev_now=$(date +%s)
  _dev_max_age_s=$((MAC_OPS_DEV_CACHE_MAX_AGE_DAYS * 86400))

  for item in "${yarn_cache}"/*; do
    [[ ! -e "${item}" ]] && continue
    local _dev_mtime _dev_sz
    _dev_mtime=$(stat -f%m "${item}" 2>/dev/null || echo 0)
    if [[ $((_dev_now - _dev_mtime)) -lt ${_dev_max_age_s} ]]; then
      mac_ops_log_debug "Skipping recent yarn cache: $(basename ${item})"
      continue
    fi
    if mac_ops_ignore_check_path "${item}"; then
      mac_ops_log_debug "User ignore (path): ${item}"
      continue
    fi
    _dev_sz=$(mac_ops_get_dir_size "${item}")
    if mac_ops_trash_move "${item}" "yarn cache cleanup" "dev-cleanup"; then
      _dev_cleaned=$((_dev_cleaned + _dev_sz))
    fi
  done

  if [[ ${_dev_cleaned} -gt 0 ]]; then
    MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + _dev_cleaned))
    MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
    mac_ops_log_info "yarn cache cleanup completed: $(mac_ops_format_bytes ${_dev_cleaned})"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# pnpm cache cleanup
# ~/.pnpm-store all
# -----------------------------------------------------------------------------
_mac_ops_dev_pnpm() {
  if ! command -v pnpm &>/dev/null; then
    mac_ops_log_debug "pnpm is not installed. Skipping."
    return 0
  fi

  local pnpm_store="${HOME}/.pnpm-store"

  if [[ ! -d "${pnpm_store}" ]]; then
    mac_ops_log_debug "pnpm store directory does not exist."
    return 0
  fi

  local store_size
  store_size=$(mac_ops_get_dir_size "${pnpm_store}")

  if [[ ${store_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will clean pnpm store: ${pnpm_store} ($(mac_ops_format_bytes ${store_size}))"
    return 0
  fi

  mac_ops_log_info "Cleaning pnpm store..."

  local _dev_now _dev_max_age_s _dev_cleaned=0
  _dev_now=$(date +%s)
  _dev_max_age_s=$((MAC_OPS_DEV_CACHE_MAX_AGE_DAYS * 86400))

  for item in "${pnpm_store}"/*; do
    [[ ! -e "${item}" ]] && continue
    local _dev_mtime _dev_sz
    _dev_mtime=$(stat -f%m "${item}" 2>/dev/null || echo 0)
    if [[ $((_dev_now - _dev_mtime)) -lt ${_dev_max_age_s} ]]; then
      mac_ops_log_debug "Skipping recent pnpm store: $(basename ${item})"
      continue
    fi
    if mac_ops_ignore_check_path "${item}"; then
      mac_ops_log_debug "User ignore (path): ${item}"
      continue
    fi
    _dev_sz=$(mac_ops_get_dir_size "${item}")
    if mac_ops_trash_move "${item}" "pnpm store cleanup" "dev-cleanup"; then
      _dev_cleaned=$((_dev_cleaned + _dev_sz))
    fi
  done

  if [[ ${_dev_cleaned} -gt 0 ]]; then
    MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + _dev_cleaned))
    MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
    mac_ops_log_info "pnpm store cleanup completed: $(mac_ops_format_bytes ${_dev_cleaned})"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# pip cache cleanup
# ~/.cache/pip all
# -----------------------------------------------------------------------------
_mac_ops_dev_pip() {
  if ! command -v pip &>/dev/null && ! command -v pip3 &>/dev/null; then
    mac_ops_log_debug "pip is not installed. Skipping."
    return 0
  fi

  local pip_cache="${HOME}/.cache/pip"

  if [[ ! -d "${pip_cache}" ]]; then
    mac_ops_log_debug "pip cache directory does not exist."
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${pip_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will clean pip cache: ${pip_cache} ($(mac_ops_format_bytes ${cache_size}))"
    return 0
  fi

  mac_ops_log_info "Cleaning pip cache..."

  local _dev_now _dev_max_age_s _dev_cleaned=0
  _dev_now=$(date +%s)
  _dev_max_age_s=$((MAC_OPS_DEV_CACHE_MAX_AGE_DAYS * 86400))

  for item in "${pip_cache}"/*; do
    [[ ! -e "${item}" ]] && continue
    local _dev_mtime _dev_sz
    _dev_mtime=$(stat -f%m "${item}" 2>/dev/null || echo 0)
    if [[ $((_dev_now - _dev_mtime)) -lt ${_dev_max_age_s} ]]; then
      mac_ops_log_debug "Skipping recent pip cache: $(basename ${item})"
      continue
    fi
    if mac_ops_ignore_check_path "${item}"; then
      mac_ops_log_debug "User ignore (path): ${item}"
      continue
    fi
    _dev_sz=$(mac_ops_get_dir_size "${item}")
    if mac_ops_trash_move "${item}" "pip cache cleanup" "dev-cleanup"; then
      _dev_cleaned=$((_dev_cleaned + _dev_sz))
    fi
  done

  if [[ ${_dev_cleaned} -gt 0 ]]; then
    MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + _dev_cleaned))
    MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
    mac_ops_log_info "pip cache cleanup completed: $(mac_ops_format_bytes ${_dev_cleaned})"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# gradle cache cleanup
# ~/.gradle/caches all
# -----------------------------------------------------------------------------
_mac_ops_dev_gradle() {
  if ! command -v gradle &>/dev/null; then
    mac_ops_log_debug "gradle is not installed. Skipping."
    return 0
  fi

  local gradle_cache="${HOME}/.gradle/caches"

  if [[ ! -d "${gradle_cache}" ]]; then
    mac_ops_log_debug "gradle cache directory does not exist."
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${gradle_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will clean gradle cache: ${gradle_cache} ($(mac_ops_format_bytes ${cache_size}))"
    return 0
  fi

  mac_ops_log_info "Cleaning gradle cache..."

  local _dev_now _dev_max_age_s _dev_cleaned=0
  _dev_now=$(date +%s)
  _dev_max_age_s=$((MAC_OPS_DEV_CACHE_MAX_AGE_DAYS * 86400))

  for item in "${gradle_cache}"/*; do
    [[ ! -e "${item}" ]] && continue
    local _dev_item_name
    _dev_item_name=$(basename "${item}")

    # Protect downloaded dependency artifacts (modules-*) from cleanup.
    # These JARs are shared across all projects and expensive to re-download.
    # Deleting them causes build failures in offline environments.
    if [[ "${_dev_item_name}" == modules-* ]]; then
      mac_ops_log_debug "Skipping gradle dependency artifacts: ${_dev_item_name}"
      continue
    fi

    local _dev_mtime _dev_sz
    _dev_mtime=$(stat -f%m "${item}" 2>/dev/null || echo 0)
    if [[ $((_dev_now - _dev_mtime)) -lt ${_dev_max_age_s} ]]; then
      mac_ops_log_debug "Skipping recent gradle cache: ${_dev_item_name}"
      continue
    fi
    if mac_ops_ignore_check_path "${item}"; then
      mac_ops_log_debug "User ignore (path): ${item}"
      continue
    fi
    _dev_sz=$(mac_ops_get_dir_size "${item}")
    if mac_ops_trash_move "${item}" "gradle cache cleanup" "dev-cleanup"; then
      _dev_cleaned=$((_dev_cleaned + _dev_sz))
    fi
  done

  if [[ ${_dev_cleaned} -gt 0 ]]; then
    MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + _dev_cleaned))
    MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
    mac_ops_log_info "gradle cache cleanup completed: $(mac_ops_format_bytes ${_dev_cleaned})"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# CocoaPods cache cleanup
# ~/Library/Caches/CocoaPods all
# -----------------------------------------------------------------------------
_mac_ops_dev_cocoapods() {
  if ! command -v pod &>/dev/null; then
    mac_ops_log_debug "CocoaPods is not installed. Skipping."
    return 0
  fi

  local pod_cache="${HOME}/Library/Caches/CocoaPods"

  if [[ ! -d "${pod_cache}" ]]; then
    mac_ops_log_debug "CocoaPods cache directory does not exist."
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${pod_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will clean CocoaPods cache: ${pod_cache} ($(mac_ops_format_bytes ${cache_size}))"
    return 0
  fi

  mac_ops_log_info "Cleaning CocoaPods cache..."

  for item in "${pod_cache}"/*; do
    [[ ! -e "${item}" ]] && continue
    mac_ops_trash_move "${item}" "CocoaPods cache cleanup" "dev-cleanup"
  done

  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + cache_size))
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
  mac_ops_log_info "CocoaPods cache cleanup completed: $(mac_ops_format_bytes ${cache_size})"

  return 0
}

# -----------------------------------------------------------------------------
# Developer tools integrated cleanup main function
# Call all sub-functions sequentially
# -----------------------------------------------------------------------------
mac_ops_dev_cleanup() {
  mac_ops_log_info "Starting developer tools cache cleanup..."

  # Execute cleanup for each development tool
  _mac_ops_dev_xcode
  _mac_ops_dev_npm
  _mac_ops_dev_yarn
  _mac_ops_dev_pnpm
  _mac_ops_dev_pip
  _mac_ops_dev_gradle
  _mac_ops_dev_cocoapods

  mac_ops_log_info "Developer tools cache cleanup completed"
  return 0
}
