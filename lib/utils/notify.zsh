# lib/utils/notify.zsh
# macOS system notification utilities

# Send macOS system notification
# Args: title, message, [always]
# Only sent when MAC_OPS_SCHEDULED=true (interactive mode already shows output
# via stdout), unless the third argument is "always" (a failed run is
# notified whether it was scheduled or started by hand)
mac_ops_notify() {
  local title="$1"
  local message="$2"

  # Do not notify if not in scheduled mode (failures pass "always")
  if [[ "$MAC_OPS_SCHEDULED" != "true" && "${3:-}" != "always" ]]; then
    return 0
  fi

  # Escape special characters before embedding in AppleScript string
  local safe_title="${title//\\/\\\\}"
  safe_title="${safe_title//\"/\\\"}"
  local safe_message="${message//\\/\\\\}"
  safe_message="${safe_message//\"/\\\"}"

  # Ignore errors even if osascript fails (e.g., headless environment)
  osascript -e "display notification \"${safe_message}\" with title \"${safe_title}\"" 2>/dev/null || true
  return 0
}

# Build the completion notification text (no side effects; testable)
# Args: cleaned_count, cleaned_bytes, killed_procs, free_before_bytes (optional),
#       free_after_bytes (optional), data_moved (optional), errors (optional),
#       warnings (optional), exit_status (optional)
# Prints the message; prints nothing when there is nothing to report. A
# failed run (errors logged or non-zero exit status) is always reported.
mac_ops_notify_message() {
  local cleaned_count="$1"
  local cleaned_bytes="$2"
  local killed_procs="$3"
  local free_before="${4:-}"
  local free_after="${5:-}"
  local data_moved="${6:-0}"
  local errors="${7:-0}"
  local warnings="${8:-0}"
  local exit_status="${9:-0}"
  local message_parts=()
  local failed=false
  [[ "${errors}" != "0" || "${exit_status}" != "0" ]] && failed=true

  if [[ "${failed}" == false && "${cleaned_count:-0}" == "0" && "${killed_procs:-0}" == "0" ]]; then
    return 0
  fi

  if [[ "${exit_status}" != "0" ]]; then
    message_parts+=("Run failed (exit status ${exit_status})")
  fi
  if [[ "${failed}" == true ]]; then
    message_parts+=("${errors} errors, ${warnings} warnings logged (see ${MAC_OPS_LOG_FILE})")
  fi

  if [[ -n "$cleaned_count" && "$cleaned_count" != "0" ]]; then
    message_parts+=("$(mac_ops_trash_summary_text "$cleaned_count" "$cleaned_bytes")")
  fi

  if [[ -n "$data_moved" && "$data_moved" != "0" ]]; then
    message_parts+=("${data_moved} data items moved")
  fi

  if [[ -n "$killed_procs" && "$killed_procs" != "0" ]]; then
    message_parts+=("${killed_procs} processes terminated")
  fi

  if [[ -n "$free_before" && -n "$free_after" ]]; then
    message_parts+=("$(mac_ops_free_change_text "$free_before" "$free_after")")
  fi

  # shellcheck disable=SC2296
  print -r -- "${(j:, :)message_parts}"
}

# Cleanup completion notification
# Args: same as mac_ops_notify_message
# Do not notify if nothing was cleaned and the run did not fail. A failed run
# (errors logged or non-zero exit status) is notified in scheduled and
# manual mode alike; a successful one only in scheduled mode.
mac_ops_notify_completion() {
  local message title="Mac-Ops Cleanup Completed" mode=""
  message=$(mac_ops_notify_message "$@")
  [[ -z "$message" ]] && return 0
  if [[ "${7:-0}" != "0" || "${9:-0}" != "0" ]]; then
    title="Mac-Ops Run Had Errors"
    mode="always"
  fi
  mac_ops_notify "$title" "$message" "${mode}"
}

# End-of-run notification: counts ERROR/WARN lines written to the log since
# line <log_start> (parallel modules included) and notifies; a run that
# failed is notified even when nothing was cleaned.
# Args: log_start, exit_status, free_before_bytes (optional), free_after_bytes (optional)
# Uses MAC_OPS_CLEANED_COUNT, MAC_OPS_CLEANED_BYTES, MAC_OPS_KILLED_COUNT,
# MAC_OPS_DATA_MOVED_COUNT.
mac_ops_notify_run_end() {
  local log_start="$1" exit_status="${2:-0}" errors warnings
  mac_ops_log_count_since "${log_start}" ERROR; errors="${REPLY}"
  mac_ops_log_count_since "${log_start}" WARN; warnings="${REPLY}"
  mac_ops_notify_completion "${MAC_OPS_CLEANED_COUNT:-0}" "${MAC_OPS_CLEANED_BYTES:-0}" \
    "${MAC_OPS_KILLED_COUNT:-0}" "${3:-}" "${4:-}" "${MAC_OPS_DATA_MOVED_COUNT:-0}" \
    "${errors}" "${warnings}" "${exit_status}"
}
