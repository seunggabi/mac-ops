# =============================================================================
# mac-ops: Cache cleanup module
# Move old caches under ~/Library/Caches to trash by directory
# Protects com.apple.* bundle ID caches
# =============================================================================

# --- Default settings ---
MAC_OPS_CACHE_MAX_AGE_DAYS=${MAC_OPS_CACHE_MAX_AGE_DAYS:-30}
MAC_OPS_CACHE_RECENT_DAYS=${MAC_OPS_CACHE_RECENT_DAYS:-7}  # Protect caches used within N days

# --- "Caches" that are not caches: never moved ---
# ms-playwright: browser binaries used by running tools
# ms-playwright-mcp: Playwright MCP server data (can hold a browser profile)
# JetBrains: IDE indexes and caches (hours to rebuild)
MAC_OPS_CACHE_PROTECTED_NAMES=("ms-playwright" "ms-playwright-mcp" "JetBrains")

# -----------------------------------------------------------------------------
# Internal: Print the package manager that owns a cache directory name
# Usage: _mac_ops_cache_manager_of <directory name>
# -----------------------------------------------------------------------------
_mac_ops_cache_manager_of() {
  case "${1}" in
    pip|pip-tools)        print -- "pip" ;;
    uv)                   print -- "uv" ;;
    Homebrew)             print -- "brew" ;;
    Yarn|yarn)            print -- "yarn" ;;
    pnpm)                 print -- "pnpm" ;;
    npm|node-gyp|_npx)    print -- "npm" ;;
    CocoaPods)            print -- "pod" ;;
  esac
  return 0
}

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
  local protected_name="" manager="" find_out="" find_rc=0 cutoff=""

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

  # Collect running apps (lsappinfo plus every running .app). When the list
  # cannot be built (lsappinfo missing, failing or empty), every cache counts
  # as in use: nothing is moved in this run.
  if ! _mac_ops_fc_load_running_apps; then
    mac_ops_log_warn "Cache cleanup skipped: running-app list unavailable (lsappinfo failed or returned nothing), every cache is treated as in use"
    return 0
  fi

  mac_ops_log_debug "Installed apps: $(echo "${installed_bundles}" | wc -l | tr -d ' ') bundles"

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

    # Skip directories that only look like caches
    for protected_name in "${MAC_OPS_CACHE_PROTECTED_NAMES[@]}"; do
      if [[ "${bundle_name}" == "${protected_name}" ]]; then
        mac_ops_log_debug "Protected, skipped (cache-cleanup): ${bundle_dir} (reason: not a disposable cache)"
        continue 2
      fi
    done

    # Skip a package manager's cache while that manager is running
    manager=$(_mac_ops_cache_manager_of "${bundle_name}")
    if [[ -n "${manager}" ]] && _mac_ops_fc_manager_running "${manager}"; then
      mac_ops_log_debug "Protected, skipped (cache-cleanup): ${bundle_dir} (reason: ${manager} is running)"
      continue
    fi

    # Skip if app is currently installed
    # Fixed-string match: a bundle ID's dots are not regex wildcards
    if print -r -- "${installed_bundles}" | grep -qxF -- "${bundle_name}"; then
      mac_ops_log_debug "Installed app cache protected: ${bundle_name}"
      continue
    fi

    # Skip if app is currently running
    if print -r -- "${_MAC_OPS_FC_RUNNING_BUNDLES}" | grep -qxF -- "${bundle_name}"; then
      mac_ops_log_debug "Running app cache protected: ${bundle_name}"
      continue
    fi

    # Security software, or still open in a running process
    if ! _mac_ops_fc_guard "${bundle_dir}" "cache-cleanup"; then
      continue
    fi

    # Check latest modification time and file count for entire bundle directory (with find at once)
    # A failed scan must not read as "nothing recent", so its exit status is checked
    local find_result
    find_out=$(find "${bundle_dir}" -type f -exec stat -f%m {} + 2>/dev/null)
    find_rc=$?
    if [[ ${find_rc} -ne 0 ]]; then
      mac_ops_log_debug "Protected, skipped (cache-cleanup): ${bundle_dir} (reason: recent-use check failed)"
      continue
    fi
    if [[ -z "${find_out}" ]]; then
      # No files inside: fall back to the directory's own modification time
      find_out=$(stat -f%m "${bundle_dir}" 2>/dev/null)
    fi
    find_result=$(print -r -- "${find_out}" | awk 'BEGIN{max=0;n=0}/^[0-9]+$/{n++;if($1>max)max=$1}END{print max,n}')
    newest_mtime="${find_result%% *}"
    file_count="${find_result##* }"

    if [[ -z "${newest_mtime}" || "${newest_mtime}" == "0" ]]; then
      mac_ops_log_debug "Protected, skipped (cache-cleanup): ${bundle_dir} (reason: modification time unavailable)"
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

      # (the guard logs the WARN with the limit, or DEBUG if it vanished)
      if ! mac_ops_check_size_guard "${bundle_dir}"; then
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
      # Absolute timestamp: bfs rejects a relative date such as "30 days ago"
      cutoff=$(_mac_ops_fc_cutoff_time "${max_age_days}")
      old_count=0
      if [[ -n "${cutoff}" ]]; then
        old_count=$(find "${bundle_dir}" -type f ! -newermt "${cutoff}" 2>/dev/null | wc -l | tr -d ' ')
      fi

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
      if _mac_ops_fc_guard "${cache_file}" "cache-cleanup" && mac_ops_is_path_safe "${cache_file}" && mac_ops_check_size_guard "${cache_file}" && ! mac_ops_ignore_check_path "${cache_file}"; then
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
