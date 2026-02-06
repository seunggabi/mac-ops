# =============================================================================
# mac-ops: Temp file cleanup module
# /tmp, /private/var/folders, ~/Library/Application Support/CrashReporter
# Different retention periods applied per path
# =============================================================================

# --- Default settings ---
MAC_OPS_TMP_MAX_AGE_DAYS=${MAC_OPS_TMP_MAX_AGE_DAYS:-3}
MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS=${MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS:-7}
MAC_OPS_CRASH_MAX_AGE_DAYS=${MAC_OPS_CRASH_MAX_AGE_DAYS:-14}

# -----------------------------------------------------------------------------
# Temp file cleanup main function
# Cleanup based on /tmp (3 days), /private/var/folders (7 days), CrashReporter (14 days)
# -----------------------------------------------------------------------------
mac_ops_tmp_cleanup() {
  mac_ops_log_info "Temp file cleanup started"

  # 1. /tmp cleanup (conservative handling as it's cleared on system reboot)
  _mac_ops_tmp_clean_path "/tmp" "${MAC_OPS_TMP_MAX_AGE_DAYS}" "tmp-expired"

  # 2. /private/var/folders cleanup (user area only, accessible without sudo)
  _mac_ops_tmp_clean_var_folders "${MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS}"

  # 3. CrashReporter cleanup
  local crash_dir="${HOME}/Library/Application Support/CrashReporter"
  if [[ -d "${crash_dir}" ]]; then
    _mac_ops_tmp_clean_path "${crash_dir}" "${MAC_OPS_CRASH_MAX_AGE_DAYS}" "crash-report-expired"
  fi

  mac_ops_log_info "Temp file cleanup completed"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Search and cleanup old files in specified path
# Usage: _mac_ops_tmp_clean_path <path> <max_days> <reason>
# -----------------------------------------------------------------------------
_mac_ops_tmp_clean_path() {
  local target_dir="${1}"
  local max_age_days="${2}"
  local reason="${3}"
  local file_list
  local count=0
  local file_size

  if [[ ! -d "${target_dir}" ]]; then
    mac_ops_log_debug "Path does not exist: ${target_dir}"
    return 0
  fi

  mac_ops_log_info "${target_dir} cleanup started (threshold: ${max_age_days} days or older)"

  # Search old files with find (based on modification time)
  # Prevent too deep search with -maxdepth limit
  file_list=$(find "${target_dir}" -maxdepth 5 -type f -mtime "+${max_age_days}" 2>/dev/null)

  if [[ -z "${file_list}" ]]; then
    mac_ops_log_debug "${target_dir}: No cleanup targets"
    return 0
  fi

  count=0
  while IFS= read -r file_path; do
    [[ -z "${file_path}" ]] && continue

    # Safety check
    if ! mac_ops_is_path_safe "${file_path}"; then
      continue
    fi

    # Size guard check
    if ! mac_ops_check_size_guard "${file_path}"; then
      continue
    fi

    # Record file size
    file_size=$(mac_ops_get_dir_size "${file_path}")

    # Move to trash
    if mac_ops_trash_move "${file_path}" "${reason}" "tmp-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done <<< "${file_list}"

  mac_ops_log_info "${target_dir}: ${count} files cleaned"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Cleanup /private/var/folders user area
# Process only current user's temp folders accessible without sudo
# Usage: _mac_ops_tmp_clean_var_folders <max_days>
# -----------------------------------------------------------------------------
_mac_ops_tmp_clean_var_folders() {
  local max_age_days="${1}"
  local var_folders="/private/var/folders"
  local file_list
  local count=0
  local file_size

  if [[ ! -d "${var_folders}" ]]; then
    mac_ops_log_debug "Path does not exist: ${var_folders}"
    return 0
  fi

  mac_ops_log_info "/private/var/folders cleanup started (threshold: ${max_age_days} days or older)"

  # Search only files accessible by current user
  # Ignore permission errors with 2>/dev/null instead of -readable
  file_list=$(find "${var_folders}" -maxdepth 6 -type f -mtime "+${max_age_days}" \
    -user "${USER}" 2>/dev/null)

  if [[ -z "${file_list}" ]]; then
    mac_ops_log_debug "/private/var/folders: No cleanup targets"
    return 0
  fi

  count=0
  while IFS= read -r file_path; do
    [[ -z "${file_path}" ]] && continue

    # Safety check
    if ! mac_ops_is_path_safe "${file_path}"; then
      continue
    fi

    # Size guard check
    if ! mac_ops_check_size_guard "${file_path}"; then
      continue
    fi

    # Record file size
    file_size=$(mac_ops_get_dir_size "${file_path}")

    # Move to trash
    if mac_ops_trash_move "${file_path}" "var-folders-expired" "tmp-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done <<< "${file_list}"

  mac_ops_log_info "/private/var/folders: ${count} files cleaned"
  return 0
}
