# =============================================================================
# mac-ops: Browser cache cleanup module
# Move Safari, Chrome, Firefox cache directories to trash
# =============================================================================

# -----------------------------------------------------------------------------
# Safari cache cleanup internal function
# -----------------------------------------------------------------------------
_mac_ops_browser_safari() {
  local safari_cache_dir="${HOME}/Library/Containers/com.apple.Safari/Data/Library/Caches"
  local cache_item="" item_basename="" item_size=0

  # Check if Safari cache directory exists
  if [[ ! -d "${safari_cache_dir}" ]]; then
    mac_ops_log_debug "Safari cache directory does not exist (Safari may not be installed)"
    return 0
  fi

  mac_ops_log_info "Starting Safari cache cleanup: ${safari_cache_dir}"

  # Safety check
  if ! mac_ops_is_path_safe "${safari_cache_dir}"; then
    mac_ops_log_error "Safari cache directory is a protected path: ${safari_cache_dir}"
    return 1
  fi

  # Iterate through subdirectories
  for cache_item in "${safari_cache_dir}"/*(N); do
    [[ -e "${cache_item}" ]] || continue

    item_basename=$(basename "${cache_item}")

    # Size guard check
    if ! mac_ops_check_size_guard "${cache_item}"; then
      item_size=$(mac_ops_get_dir_size "${cache_item}")
      mac_ops_log_warn "Skipping due to size guard exceeded: Safari/${item_basename} ($(mac_ops_format_bytes ${item_size}))"
      continue
    fi

    item_size=$(mac_ops_get_dir_size "${cache_item}")
    mac_ops_log_info "Cleaning Safari cache item: ${item_basename} ($(mac_ops_format_bytes ${item_size}))"

    if mac_ops_ignore_check_path "${cache_item}"; then
      mac_ops_log_debug "User ignore (path): ${cache_item}"
      continue
    fi

    if mac_ops_trash_move "${cache_item}" "browser-cache" "safari"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + item_size))
    fi
  done

  mac_ops_log_info "Safari cache cleanup completed"
  return 0
}

# -----------------------------------------------------------------------------
# Chrome cache cleanup internal function
# -----------------------------------------------------------------------------
_mac_ops_browser_chrome() {
  local chrome_cache_base="${HOME}/Library/Caches/Google/Chrome/Default"
  local cache_dir="" cache_item="" item_basename="" item_size=0

  # Check if Chrome cache base directory exists
  if [[ ! -d "${chrome_cache_base}" ]]; then
    mac_ops_log_debug "Chrome cache directory does not exist (Chrome may not be installed)"
    return 0
  fi

  mac_ops_log_info "Starting Chrome cache cleanup: ${chrome_cache_base}"

  # Process Cache and Code Cache directories
  for cache_dir in "${chrome_cache_base}/Cache" "${chrome_cache_base}/Code Cache"; do
    if [[ ! -d "${cache_dir}" ]]; then
      mac_ops_log_debug "Chrome cache subdirectory not found: ${cache_dir}"
      continue
    fi

    # Safety check
    if ! mac_ops_is_path_safe "${cache_dir}"; then
      mac_ops_log_error "Chrome cache directory is a protected path: ${cache_dir}"
      continue
    fi

    # Iterate through subdirectories
    for cache_item in "${cache_dir}"/*(N); do
      [[ -e "${cache_item}" ]] || continue

      item_basename=$(basename "${cache_item}")

      # Size guard check
      if ! mac_ops_check_size_guard "${cache_item}"; then
        item_size=$(mac_ops_get_dir_size "${cache_item}")
        mac_ops_log_warn "Skipping due to size guard exceeded: Chrome/$(basename ${cache_dir})/${item_basename} ($(mac_ops_format_bytes ${item_size}))"
        continue
      fi

      item_size=$(mac_ops_get_dir_size "${cache_item}")
      mac_ops_log_info "Cleaning Chrome cache item: $(basename ${cache_dir})/${item_basename} ($(mac_ops_format_bytes ${item_size}))"

      if mac_ops_ignore_check_path "${cache_item}"; then
      mac_ops_log_debug "User ignore (path): ${cache_item}"
      continue
    fi

    if mac_ops_trash_move "${cache_item}" "browser-cache" "chrome"; then
        MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
        MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + item_size))
      fi
    done
  done

  mac_ops_log_info "Chrome cache cleanup completed"
  return 0
}

# -----------------------------------------------------------------------------
# Firefox cache cleanup internal function
# -----------------------------------------------------------------------------
_mac_ops_browser_firefox() {
  local firefox_cache_base="${HOME}/Library/Caches/Firefox/Profiles"
  local profile_dir="" cache_dir="" cache_item="" item_basename="" item_size=0

  # Check if Firefox cache base directory exists
  if [[ ! -d "${firefox_cache_base}" ]]; then
    mac_ops_log_debug "Firefox cache directory does not exist (Firefox may not be installed)"
    return 0
  fi

  mac_ops_log_info "Starting Firefox cache cleanup: ${firefox_cache_base}"

  # Iterate through profile directories (*.default*)
  for profile_dir in "${firefox_cache_base}"/*.default*(/N); do
    cache_dir="${profile_dir}/cache2"

    if [[ ! -d "${cache_dir}" ]]; then
      mac_ops_log_debug "Firefox profile cache not found: $(basename ${profile_dir})"
      continue
    fi

    # Safety check
    if ! mac_ops_is_path_safe "${cache_dir}"; then
      mac_ops_log_error "Firefox cache directory is a protected path: ${cache_dir}"
      continue
    fi

    # Iterate through subdirectories
    for cache_item in "${cache_dir}"/*(N); do
      [[ -e "${cache_item}" ]] || continue

      item_basename=$(basename "${cache_item}")

      # Size guard check
      if ! mac_ops_check_size_guard "${cache_item}"; then
        item_size=$(mac_ops_get_dir_size "${cache_item}")
        mac_ops_log_warn "Skipping due to size guard exceeded: Firefox/$(basename ${profile_dir})/${item_basename} ($(mac_ops_format_bytes ${item_size}))"
        continue
      fi

      item_size=$(mac_ops_get_dir_size "${cache_item}")
      mac_ops_log_info "Cleaning Firefox cache item: $(basename ${profile_dir})/${item_basename} ($(mac_ops_format_bytes ${item_size}))"

      if mac_ops_ignore_check_path "${cache_item}"; then
      mac_ops_log_debug "User ignore (path): ${cache_item}"
      continue
    fi

    if mac_ops_trash_move "${cache_item}" "browser-cache" "firefox"; then
        MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
        MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + item_size))
      fi
    done
  done

  mac_ops_log_info "Firefox cache cleanup completed"
  return 0
}

# -----------------------------------------------------------------------------
# Browser cache cleanup main function
# Clean Safari, Chrome, Firefox cache sequentially
# -----------------------------------------------------------------------------
mac_ops_browser_cleanup() {
  mac_ops_log_info "Starting browser cache cleanup"

  # Safari cache cleanup
  _mac_ops_browser_safari

  # Chrome cache cleanup
  _mac_ops_browser_chrome

  # Firefox cache cleanup
  _mac_ops_browser_firefox

  mac_ops_log_info "Browser cache cleanup completed"
  return 0
}
