# =============================================================================
# mac-ops: Developer tools cache cleanup module
# Integrated cleanup for Xcode, npm, yarn, pnpm, pip, gradle, CocoaPods, etc.
# =============================================================================

# --- Default settings ---
# Only delete cache items older than this many days (prevents wiping active caches)
MAC_OPS_DEV_CACHE_MAX_AGE_DAYS=${MAC_OPS_DEV_CACHE_MAX_AGE_DAYS:-30}

# -----------------------------------------------------------------------------
# Xcode cache cleanup
# DerivedData and CoreSimulator cache; Archives are only reported
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

  # DerivedData and simulator caches are in use while Xcode builds
  if _mac_ops_fc_exec_running "/Xcode.app/Contents/MacOS/Xcode" || _mac_ops_fc_tool_running xcodebuild; then
    mac_ops_log_debug "Protected, skipped (dev-cleanup): Xcode caches (reason: Xcode is running)"
    return 0
  fi

  mac_ops_log_info "Cleaning Xcode cache..."

  local _dev_cutoff="" _dev_sz=0 _dev_cleaned=0
  _dev_cutoff=$(_mac_ops_fc_cutoff_time "${MAC_OPS_DEV_CACHE_MAX_AGE_DAYS}")

  # DerivedData: only items with nothing inside modified or read within
  # MAC_OPS_DEV_CACHE_MAX_AGE_DAYS (a project opened last week keeps its index).
  # Dry-run takes the same path, so it lists exactly the items a real run
  # would move (trash_move only reports in dry-run).
  if [[ -d "${xcode_derived}" ]]; then
    for item in "${xcode_derived}"/*(N); do
      [[ ! -e "${item}" ]] && continue
      _mac_ops_fc_guard "${item}" "dev-cleanup" "${_dev_cutoff}" || continue
      if mac_ops_ignore_check_path "${item}"; then
        mac_ops_log_debug "User ignore (path): ${item}"
        continue
      fi
      _dev_sz=$(mac_ops_get_dir_size "${item}")
      if mac_ops_trash_move "${item}" "Xcode DerivedData cleanup" "dev-cleanup"; then
        _dev_cleaned=$((_dev_cleaned + _dev_sz))
      fi
    done

    if [[ "${MAC_OPS_DRY_RUN}" != "true" && ${_dev_cleaned} -gt 0 ]]; then
      MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + _dev_cleaned))
      MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
      mac_ops_log_info "Xcode DerivedData cleanup completed: $(mac_ops_format_bytes ${_dev_cleaned})"
    fi
  fi

  # Archives are shipped build products with their dSYMs (needed to
  # symbolicate crash reports): data, not cache. Reported, never moved.
  if [[ -d "${xcode_archives}" ]]; then
    local archive_count=0
    local archive_size=0
    local archive=""
    while IFS= read -r archive; do
      [[ -z "${archive}" ]] && continue
      archive_count=$((archive_count + 1))
      archive_size=$((archive_size + $(mac_ops_get_dir_size "${archive}")))
    done < <(find "${xcode_archives}" -maxdepth 3 -type d -name '*.xcarchive' -prune 2>/dev/null)
    if [[ ${archive_count} -gt 0 ]]; then
      mac_ops_log_info "Xcode Archives: ${archive_count} archives, $(mac_ops_format_bytes ${archive_size}) in ${xcode_archives} (reported only, never moved; delete old ones in Xcode Organizer)"
    fi
  fi

  # CoreSimulator Caches cleanup
  if [[ -d "${xcode_simulator}" ]]; then
    local sim_size
    sim_size=$(mac_ops_get_dir_size "${xcode_simulator}")

    if [[ ${sim_size} -gt 0 ]]; then
      # Dry-run takes the same path as a real run (see DerivedData above)
      for item in "${xcode_simulator}"/*(N); do
        [[ ! -e "${item}" ]] && continue
        _mac_ops_fc_guard "${item}" "dev-cleanup" || continue
        mac_ops_trash_move "${item}" "Xcode Simulator cache cleanup" "dev-cleanup"
      done

      if [[ "${MAC_OPS_DRY_RUN}" != "true" ]]; then
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

  # The cache is in use while its package manager runs
  if _mac_ops_fc_manager_running "npm"; then
    mac_ops_log_debug "Protected, skipped (dev-cleanup): ${npm_cache} (reason: npm is running)"
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

  local _dev_cutoff _dev_sz _dev_item_name _dev_cleaned=0
  _dev_cutoff=$(_mac_ops_fc_cutoff_time "${MAC_OPS_DEV_CACHE_MAX_AGE_DAYS}")

  for item in "${npm_cache}"/*(N); do
    [[ ! -e "${item}" ]] && continue
    # Skip security software paths, open items and anything used inside
    # within the threshold (the top-level mtime alone says nothing)
    if ! _mac_ops_fc_guard "${item}" "dev-cleanup" "${_dev_cutoff}"; then
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

  # The cache is in use while its package manager runs
  if _mac_ops_fc_manager_running "yarn"; then
    mac_ops_log_debug "Protected, skipped (dev-cleanup): ${yarn_cache} (reason: yarn is running)"
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

  local _dev_cutoff _dev_sz _dev_item_name _dev_cleaned=0
  _dev_cutoff=$(_mac_ops_fc_cutoff_time "${MAC_OPS_DEV_CACHE_MAX_AGE_DAYS}")

  for item in "${yarn_cache}"/*(N); do
    [[ ! -e "${item}" ]] && continue
    # Skip security software paths, open items and anything used inside
    # within the threshold (the top-level mtime alone says nothing)
    if ! _mac_ops_fc_guard "${item}" "dev-cleanup" "${_dev_cutoff}"; then
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

  # The cache is in use while its package manager runs
  if _mac_ops_fc_manager_running "pnpm"; then
    mac_ops_log_debug "Protected, skipped (dev-cleanup): ${pnpm_store} (reason: pnpm is running)"
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

  local _dev_cutoff _dev_sz _dev_item_name _dev_cleaned=0
  _dev_cutoff=$(_mac_ops_fc_cutoff_time "${MAC_OPS_DEV_CACHE_MAX_AGE_DAYS}")

  for item in "${pnpm_store}"/*(N); do
    [[ ! -e "${item}" ]] && continue
    # Skip security software paths, open items and anything used inside
    # within the threshold (the top-level mtime alone says nothing)
    if ! _mac_ops_fc_guard "${item}" "dev-cleanup" "${_dev_cutoff}"; then
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

  # The cache is in use while its package manager runs
  if _mac_ops_fc_manager_running "pip"; then
    mac_ops_log_debug "Protected, skipped (dev-cleanup): ${pip_cache} (reason: pip is running)"
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

  local _dev_cutoff _dev_sz _dev_item_name _dev_cleaned=0
  _dev_cutoff=$(_mac_ops_fc_cutoff_time "${MAC_OPS_DEV_CACHE_MAX_AGE_DAYS}")

  for item in "${pip_cache}"/*(N); do
    [[ ! -e "${item}" ]] && continue
    # Skip security software paths, open items and anything used inside
    # within the threshold (the top-level mtime alone says nothing)
    if ! _mac_ops_fc_guard "${item}" "dev-cleanup" "${_dev_cutoff}"; then
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

  # The cache is in use while its package manager runs
  if _mac_ops_fc_manager_running "gradle"; then
    mac_ops_log_debug "Protected, skipped (dev-cleanup): ${gradle_cache} (reason: gradle is running)"
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

  local _dev_cutoff _dev_sz _dev_item_name _dev_cleaned=0
  _dev_cutoff=$(_mac_ops_fc_cutoff_time "${MAC_OPS_DEV_CACHE_MAX_AGE_DAYS}")

  for item in "${gradle_cache}"/*(N); do
    [[ ! -e "${item}" ]] && continue
    _dev_item_name=$(basename "${item}")

    # Protect downloaded dependency artifacts (modules-*) from cleanup.
    # These JARs are shared across all projects and expensive to re-download.
    # Deleting them causes build failures in offline environments.
    if [[ "${_dev_item_name}" == modules-* ]]; then
      mac_ops_log_debug "Skipping gradle dependency artifacts: ${_dev_item_name}"
      continue
    fi

    # Skip security software paths, open items and anything used inside
    # within the threshold (the top-level mtime alone says nothing)
    if ! _mac_ops_fc_guard "${item}" "dev-cleanup" "${_dev_cutoff}"; then
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

  # The cache is in use while CocoaPods runs
  if _mac_ops_fc_manager_running "pod"; then
    mac_ops_log_debug "Protected, skipped (dev-cleanup): ${pod_cache} (reason: pod is running)"
    return 0
  fi

  local cache_size
  cache_size=$(mac_ops_get_dir_size "${pod_cache}")

  if [[ ${cache_size} -eq 0 ]]; then
    return 0
  fi

  mac_ops_log_info "Cleaning CocoaPods cache..."

  local _dev_cutoff="" _dev_sz=0 _dev_cleaned=0
  _dev_cutoff=$(_mac_ops_fc_cutoff_time "${MAC_OPS_DEV_CACHE_MAX_AGE_DAYS}")

  # Only items with nothing inside used within MAC_OPS_DEV_CACHE_MAX_AGE_DAYS.
  # Dry-run takes the same path, so it lists exactly what a real run would move
  for item in "${pod_cache}"/*(N); do
    [[ ! -e "${item}" ]] && continue
    _mac_ops_fc_guard "${item}" "dev-cleanup" "${_dev_cutoff}" || continue
    if mac_ops_ignore_check_path "${item}"; then
      mac_ops_log_debug "User ignore (path): ${item}"
      continue
    fi
    _dev_sz=$(mac_ops_get_dir_size "${item}")
    if mac_ops_trash_move "${item}" "CocoaPods cache cleanup" "dev-cleanup"; then
      _dev_cleaned=$((_dev_cleaned + _dev_sz))
    fi
  done

  if [[ "${MAC_OPS_DRY_RUN}" == "true" || ${_dev_cleaned} -eq 0 ]]; then
    return 0
  fi

  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + _dev_cleaned))
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))
  mac_ops_log_info "CocoaPods cache cleanup completed: $(mac_ops_format_bytes ${_dev_cleaned})"

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
