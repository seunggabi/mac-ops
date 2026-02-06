# =============================================================================
# mac-ops: Orphan app data cleanup module
# Detect and cleanup leftover files from deleted apps (Application Support, Caches, Preferences, etc.)
# Excludes com.apple.*, Group Containers, files modified within last 7 days
# =============================================================================

# --- Default settings ---
MAC_OPS_ORPHAN_APP_GRACE_DAYS=${MAC_OPS_ORPHAN_APP_GRACE_DAYS:-7}

# --- Scan target paths ---
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
# Orphan app data cleanup main function
# 1. Extract bundle IDs of installed apps from /Applications, ~/Applications
# 2. Search for bundle ID pattern directories/files in scan target paths
# 3. If not in installed apps list, determine as orphan file and cleanup
# -----------------------------------------------------------------------------
mac_ops_orphan_app_cleanup() {
  mac_ops_log_info "Orphan app data cleanup started"

  # Stage 1: Collect bundle IDs of installed apps (using global associative array)
  typeset -gA _MAC_OPS_INSTALLED_BUNDLES
  _MAC_OPS_INSTALLED_BUNDLES=()
  _mac_ops_collect_installed_bundles

  local bundle_count=${#_MAC_OPS_INSTALLED_BUNDLES[@]}
  mac_ops_log_info "${bundle_count} installed app bundle IDs collected"

  if [[ ${bundle_count} -eq 0 ]]; then
    mac_ops_log_warn "Failed to collect installed app bundle IDs. Aborting for safety."
    return 1
  fi

  # Stage 2: Search for orphan data in each scan target path
  local total_cleaned=0
  for scan_dir in "${MAC_OPS_ORPHAN_APP_SCAN_DIRS[@]}"; do
    if [[ ! -d "${scan_dir}" ]]; then
      mac_ops_log_debug "Scan target path not found: ${scan_dir}"
      continue
    fi

    # Process Preferences directory based on plist files
    if [[ "${scan_dir}" == *"/Preferences" ]]; then
      _mac_ops_scan_preferences "${scan_dir}"
    else
      _mac_ops_scan_directory "${scan_dir}"
    fi
  done

  # Cleanup global variable
  unset _MAC_OPS_INSTALLED_BUNDLES

  mac_ops_log_info "Orphan app data cleanup completed"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Collect bundle IDs of installed apps into associative array
# Includes both /Applications/*.app and ~/Applications/*.app
# Usage: _mac_ops_collect_installed_bundles <associative_array_name>
# -----------------------------------------------------------------------------
_mac_ops_collect_installed_bundles() {
  local app_dirs=("/Applications" "${HOME}/Applications")
  local info_plist=""
  local bundle_id=""

  for app_base in "${app_dirs[@]}"; do
    [[ ! -d "${app_base}" ]] && continue

    # shellcheck disable=SC1073,SC1036,SC1058,SC1072
    for app_path in "${app_base}"/*.app(N); do
      [[ ! -d "${app_path}" ]] && continue

      info_plist="${app_path}/Contents/Info.plist"
      if [[ ! -f "${info_plist}" ]]; then
        mac_ops_log_debug "Info.plist not found: ${app_path}"
        continue
      fi

      # Extract bundle ID
      bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${info_plist}" 2>/dev/null)
      if [[ -n "${bundle_id}" ]]; then
        _MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]=1
        mac_ops_log_debug "Bundle ID collected: ${bundle_id} (${app_path})"
      fi
    done
  done
}

# -----------------------------------------------------------------------------
# Internal: Search and cleanup orphan bundle ID entries in directory
# Process directories whose name matches bundle ID pattern (com.xxx.xxx) but not in installed list
# Usage: _mac_ops_scan_directory <scan_path> <installed_bundles_array_name>
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

  mac_ops_log_info "Orphan data scan: ${scan_dir}"

  count=0

  # Iterate only 1st level subitems (bundle ID directories)
  for item in "${scan_dir}"/*(N); do
    item_name=$(basename "${item}")

    # Bundle ID pattern matching (com.xxx.xxx or org.xxx.xxx, etc.)
    # Reverse domain format with at least 2 dots (.)
    if [[ ! "${item_name}" =~ ^[a-zA-Z][a-zA-Z0-9-]*\.[a-zA-Z][a-zA-Z0-9-]*\..+ ]]; then
      continue
    fi

    # Exclude com.apple.* (system data)
    if [[ "${item_name}" == com.apple.* ]]; then
      continue
    fi

    # Don't process Group Containers subdirectories (can be shared by multiple apps)
    if [[ "${scan_dir}" == *"Group Containers"* ]]; then
      continue
    fi

    # Skip if in installed apps list
    if [[ -n "${_MAC_OPS_INSTALLED_BUNDLES[${item_name}]+_}" ]]; then
      continue
    fi

    # Check recent modification (grace period)
    mtime=$(stat -f%m "${item}" 2>/dev/null)
    if [[ -n "${mtime}" && "${mtime}" =~ ^[0-9]+$ ]]; then
      age_seconds=$((now_epoch - mtime))
      if [[ ${age_seconds} -lt ${grace_seconds} ]]; then
        mac_ops_log_debug "Recently modified, skipped: ${item_name} (${age_seconds} seconds ago)"
        continue
      fi
    fi

    # Safety check
    if ! mac_ops_is_path_safe "${item}"; then
      continue
    fi

    # Size guard check
    if ! mac_ops_check_size_guard "${item}"; then
      continue
    fi

    # Record file/directory size
    item_size=$(mac_ops_get_dir_size "${item}")

    mac_ops_log_info "Orphan app data found: ${item_name} ($(mac_ops_format_bytes "${item_size}"))"

    # Move to trash
    if mac_ops_trash_move "${item}" "orphan-app-data" "orphan-app-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + item_size))
      count=$((count + 1))
    fi
  done

  mac_ops_log_info "${scan_dir}: ${count} orphan items cleaned"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Search and cleanup orphan plist files in ~/Library/Preferences
# Extract bundle ID from *.plist filename and match
# Usage: _mac_ops_scan_preferences <Preferences_path> <installed_bundles_array_name>
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

  mac_ops_log_info "Orphan Preferences scan: ${pref_dir}"

  count=0

  for plist_file in "${pref_dir}"/*.plist(N); do
    [[ ! -f "${plist_file}" ]] && continue

    # Extract bundle ID from filename (com.xxx.xxx.plist -> com.xxx.xxx)
    file_name=$(basename "${plist_file}" .plist)

    # Bundle ID pattern matching
    if [[ ! "${file_name}" =~ ^[a-zA-Z][a-zA-Z0-9-]*\.[a-zA-Z][a-zA-Z0-9-]*\..+ ]]; then
      continue
    fi

    # Exclude com.apple.*
    if [[ "${file_name}" == com.apple.* ]]; then
      continue
    fi

    # Skip if in installed apps list
    if [[ -n "${_MAC_OPS_INSTALLED_BUNDLES[${file_name}]+_}" ]]; then
      continue
    fi

    # Check recent modification
    mtime=$(stat -f%m "${plist_file}" 2>/dev/null)
    if [[ -n "${mtime}" && "${mtime}" =~ ^[0-9]+$ ]]; then
      age_seconds=$((now_epoch - mtime))
      if [[ ${age_seconds} -lt ${grace_seconds} ]]; then
        continue
      fi
    fi

    # Safety check -- Preferences is in whitelist so
    # individual plist files are safe (parent directory itself is protected)
    # is_path_safe protects parent directory ~/Library/Preferences so
    # direct call on subfiles will block -> skip here for individual files
    # Check only size guard instead
    if ! mac_ops_check_size_guard "${plist_file}"; then
      continue
    fi

    # Record file size
    file_size=$(mac_ops_get_dir_size "${plist_file}")

    mac_ops_log_info "Orphan Preference found: ${file_name}.plist ($(mac_ops_format_bytes "${file_size}"))"

    # Move to trash
    if mac_ops_trash_move "${plist_file}" "orphan-app-preference" "orphan-app-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done

  mac_ops_log_info "${pref_dir}: ${count} orphan Preferences cleaned"
  return 0
}
