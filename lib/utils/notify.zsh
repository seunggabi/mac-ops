# lib/utils/notify.zsh
# macOS system notification utilities

# Send macOS system notification
# Args: title, message
# Only send notification when MAC_OPS_SCHEDULED=true (interactive mode already shows output via stdout)
mac_ops_notify() {
  local title="$1"
  local message="$2"

  # Do not notify if not in scheduled mode
  if [[ "$MAC_OPS_SCHEDULED" != "true" ]]; then
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
#       free_after_bytes (optional), data_moved (optional)
# Prints the message; prints nothing when there is nothing to report
mac_ops_notify_message() {
  local cleaned_count="$1"
  local cleaned_bytes="$2"
  local killed_procs="$3"
  local free_before="${4:-}"
  local free_after="${5:-}"
  local data_moved="${6:-0}"
  local message_parts=()

  if [[ "${cleaned_count:-0}" == "0" && "${killed_procs:-0}" == "0" ]]; then
    return 0
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
# Do not notify if no items were cleaned (count is 0)
mac_ops_notify_completion() {
  local message
  message=$(mac_ops_notify_message "$@")
  [[ -z "$message" ]] && return 0
  mac_ops_notify "Mac-Ops Cleanup Completed" "$message"
}
