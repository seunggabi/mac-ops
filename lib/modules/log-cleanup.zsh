# =============================================================================
# mac-ops: Log file cleanup module
# Move old log files under ~/Library/Logs to trash
# Targets .log, .crash, .diag, .spin, .hang extensions
# =============================================================================

# --- Default settings ---
MAC_OPS_LOG_CLEANUP_MAX_AGE_DAYS=${MAC_OPS_LOG_CLEANUP_MAX_AGE_DAYS:-7}
MAC_OPS_DIAG_REPORT_MAX_AGE_DAYS=${MAC_OPS_DIAG_REPORT_MAX_AGE_DAYS:-14}

# --- Cleanup target extensions ---
MAC_OPS_LOG_EXTENSIONS=("log" "crash" "diag" "spin" "hang")

# -----------------------------------------------------------------------------
# Log cleanup main function
# Cleanup based on ~/Library/Logs (7 days), DiagnosticReports (14 days)
# -----------------------------------------------------------------------------
mac_ops_log_cleanup() {
  local logs_dir="${HOME}/Library/Logs"
  local diag_dir="${HOME}/Library/Logs/DiagnosticReports"

  mac_ops_log_info "Log cleanup started"

  # 1. ~/Library/Logs general log cleanup
  if [[ -d "${logs_dir}" ]]; then
    _mac_ops_log_clean_dir "${logs_dir}" "${MAC_OPS_LOG_CLEANUP_MAX_AGE_DAYS}" "log-expired"
  else
    mac_ops_log_debug "Log directory does not exist: ${logs_dir}"
  fi

  # 2. DiagnosticReports cleanup (longer retention period applied)
  if [[ -d "${diag_dir}" ]]; then
    _mac_ops_log_clean_dir "${diag_dir}" "${MAC_OPS_DIAG_REPORT_MAX_AGE_DAYS}" "diagnostic-report-expired"
  else
    mac_ops_log_debug "Diagnostic report directory does not exist: ${diag_dir}"
  fi

  mac_ops_log_info "Log cleanup completed"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Cleanup old files with target extensions in directory
# Usage: _mac_ops_log_clean_dir <directory> <max_days> <reason>
# -----------------------------------------------------------------------------
_mac_ops_log_clean_dir() {
  local target_dir="${1}"
  local max_age_days="${2}"
  local reason="${3}"
  local now_epoch
  local threshold_seconds=$((max_age_days * 86400))
  local find_args=()
  local first=true
  local count=0
  local file_list
  local mtime
  local age_seconds
  local file_size

  now_epoch=$(date +%s)

  mac_ops_log_info "${target_dir} log cleanup (threshold: ${max_age_days} days or older)"

  # Search target extension files with find command
  # Match target extensions by connecting -name conditions with OR
  first=true
  for ext in "${MAC_OPS_LOG_EXTENSIONS[@]}"; do
    if [[ "${first}" == "true" ]]; then
      find_args+=("-name" "*.${ext}")
      first=false
    else
      find_args+=("-o" "-name" "*.${ext}")
    fi
  done

  count=0

  # Search target files with find
  file_list=$(find "${target_dir}" -maxdepth 5 -type f \( "${find_args[@]}" \) 2>/dev/null)

  if [[ -z "${file_list}" ]]; then
    mac_ops_log_debug "${target_dir}: No cleanup targets"
    return 0
  fi

  while IFS= read -r file_path; do
    [[ -z "${file_path}" ]] && continue

    # Check file modification time
    mtime=$(stat -f%m "${file_path}" 2>/dev/null)
    if [[ -z "${mtime}" || ! "${mtime}" =~ ^[0-9]+$ ]]; then
      mac_ops_log_debug "Failed to retrieve modification time: ${file_path}"
      continue
    fi

    # Calculate elapsed time
    age_seconds=$((now_epoch - mtime))
    if [[ ${age_seconds} -lt ${threshold_seconds} ]]; then
      continue
    fi

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
    if mac_ops_trash_move "${file_path}" "${reason}" "log-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done <<< "${file_list}"

  mac_ops_log_info "${target_dir}: ${count} log files cleaned"
  return 0
}
