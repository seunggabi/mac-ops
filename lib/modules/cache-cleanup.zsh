# =============================================================================
# mac-ops: Cache cleanup module
# Move old caches under ~/Library/Caches to trash by directory
# Protects com.apple.* bundle ID caches
# =============================================================================

# --- Default settings ---
MAC_OPS_CACHE_MAX_AGE_DAYS=${MAC_OPS_CACHE_MAX_AGE_DAYS:-30}
MAC_OPS_CACHE_RECENT_DAYS=${MAC_OPS_CACHE_RECENT_DAYS:-7}  # Protect caches used within N days

# -----------------------------------------------------------------------------
# Cache cleanup main function
# Performance optimized by processing bundle directories as units
# -----------------------------------------------------------------------------
mac_ops_cache_cleanup() {
  local cache_dir="${HOME}/Library/Caches"
  local max_age_days="${MAC_OPS_CACHE_MAX_AGE_DAYS}"
  local recent_days="${MAC_OPS_CACHE_RECENT_DAYS}"
  local now_epoch
  now_epoch=$(date +%s)
  local threshold_seconds=$((max_age_days * 86400))
  local recent_threshold_seconds=$((recent_days * 86400))
  local bundle_name="" newest_mtime="" age_seconds=0 dir_size=0 file_count=0
  local old_count=0 file_basename="" mtime="" file_size=0

  mac_ops_log_info "Cache cleanup started: ${cache_dir} (delete: >${max_age_days}d, protect recent: <${recent_days}d)"

  # Collect installed app bundle IDs (from /Applications and ~/Applications)
  local installed_bundles
  installed_bundles=$(
    {
      find /Applications ~/Applications -maxdepth 3 -name "*.app" 2>/dev/null | while IFS= read -r app_path; do
        defaults read "${app_path}/Contents/Info.plist" CFBundleIdentifier 2>/dev/null
      done
    } | sort -u
  )

  # Collect running app bundle IDs
  local running_bundles
  running_bundles=$(
    lsappinfo list 2>/dev/null | grep 'bundleID=' | sed 's/.*bundleID="\([^"]*\)".*/\1/' | grep -v '^\[' | sort -u
  )

  mac_ops_log_debug "Installed apps: $(echo "${installed_bundles}" | wc -l | tr -d ' ') bundles"
  mac_ops_log_debug "Running apps: $(echo "${running_bundles}" | wc -l | tr -d ' ') bundles"

  # Check if cache directory exists
  if [[ ! -d "${cache_dir}" ]]; then
    mac_ops_log_warn "Cache directory does not exist: ${cache_dir}"
    return 0
  fi

  # Cache directory safety check
  if ! mac_ops_is_path_safe "${cache_dir}"; then
    mac_ops_log_error "Cache directory is a protected path: ${cache_dir}"
    return 1
  fi

  # Iterate subdirectories (bundle ID units)
  for bundle_dir in "${cache_dir}"/*(/N); do
    bundle_name=$(basename "${bundle_dir}")

    # Skip com.apple.* bundle IDs
    if [[ "${bundle_name}" == com.apple.* ]]; then
      mac_ops_log_debug "Apple cache skipped: ${bundle_name}"
      continue
    fi

    # Skip if app is currently installed
    if echo "${installed_bundles}" | grep -qx "${bundle_name}"; then
      mac_ops_log_debug "Installed app cache protected: ${bundle_name}"
      continue
    fi

    # Skip if app is currently running
    if echo "${running_bundles}" | grep -qx "${bundle_name}"; then
      mac_ops_log_debug "Running app cache protected: ${bundle_name}"
      continue
    fi

    # Check latest modification time and file count for entire bundle directory (with find at once)
    local find_result
    find_result=$(find "${bundle_dir}" -type f -exec stat -f%m {} + 2>/dev/null | awk 'BEGIN{max=0;n=0}{n++;if($1>max)max=$1}END{print max,n}')
    newest_mtime="${find_result%% *}"
    file_count="${find_result##* }"

    if [[ -z "${newest_mtime}" ]]; then
      continue
    fi

    age_seconds=$((now_epoch - newest_mtime))

    # Skip if cache was recently used (within recent_days)
    if [[ ${age_seconds} -lt ${recent_threshold_seconds} ]]; then
      mac_ops_log_debug "Recently used cache protected: ${bundle_name} (used within ${recent_days} days)"
      continue
    fi

    if [[ ${age_seconds} -ge ${threshold_seconds} ]]; then
      dir_size=$(mac_ops_get_dir_size "${bundle_dir}")

      if ! mac_ops_check_size_guard "${bundle_dir}"; then
        mac_ops_log_warn "Skipped due to size guard exceeded: ${bundle_name} ($(mac_ops_format_bytes ${dir_size}))"
        continue
      fi

      mac_ops_log_info "Cache directory cleanup: ${bundle_name} (${file_count} files, $(mac_ops_format_bytes ${dir_size}))"

      if mac_ops_ignore_check_path "${bundle_dir}"; then
        mac_ops_log_debug "User ignore (path): ${bundle_dir}"
        continue
      fi

      if mac_ops_trash_move "${bundle_dir}" "cache-expired" "cache-cleanup"; then
        MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + file_count))
        MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + dir_size))
      fi
    else
      old_count=$(find "${bundle_dir}" -type f ! -newermt "${max_age_days} days ago" 2>/dev/null | wc -l | tr -d ' ')

      if [[ ${old_count} -gt 0 ]]; then
        mac_ops_log_debug "Some cache files old: ${bundle_name} (${old_count} files exceed ${max_age_days} days, deferred due to newer files existing)"
      fi
    fi
  done

  # Process top-level files too (non-directory files)
  for cache_file in "${cache_dir}"/*(-.N); do
    file_basename=$(basename "${cache_file}")

    # Skip com.apple.* files
    if [[ "${file_basename}" == com.apple.* ]]; then
      mac_ops_log_debug "Apple cache file skipped: ${file_basename}"
      continue
    fi

    mtime=$(stat -f%m "${cache_file}" 2>/dev/null) || continue
    age_seconds=$((now_epoch - mtime))

    if [[ ${age_seconds} -ge ${threshold_seconds} ]]; then
      if mac_ops_is_path_safe "${cache_file}" && mac_ops_check_size_guard "${cache_file}" && ! mac_ops_ignore_check_path "${cache_file}"; then
        file_size=$(mac_ops_get_dir_size "${cache_file}")
        if mac_ops_trash_move "${cache_file}" "cache-expired" "cache-cleanup"; then
          MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
          MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
        fi
      fi
    fi
  done

  mac_ops_log_info "Cache cleanup completed"
  return 0
}
