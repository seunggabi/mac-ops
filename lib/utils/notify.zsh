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

  # Ignore errors even if osascript fails (e.g., headless environment)
  osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
  return 0
}

# Cleanup completion notification
# Args: cleaned_count, cleaned_bytes, killed_procs
# Do not notify if no items were cleaned (count is 0)
mac_ops_notify_completion() {
  local cleaned_count="$1"
  local cleaned_bytes="$2"
  local killed_procs="$3"
  local formatted_size
  local message_parts=()
  local message

  # Do not notify if no items were cleaned
  if [[ "$cleaned_count" == "0" && "$killed_procs" == "0" ]]; then
    return 0
  fi

  # Compose message
  if [[ -n "$cleaned_count" && "$cleaned_count" != "0" ]]; then
    formatted_size=$(mac_ops_format_bytes "$cleaned_bytes")
    message_parts+=("${cleaned_count} files cleaned, ${formatted_size} freed")
  fi

  if [[ -n "$killed_procs" && "$killed_procs" != "0" ]]; then
    message_parts+=("${killed_procs} processes terminated")
  fi

  # Join message parts
  message="${(j:, :)message_parts}"

  # Send notification
  mac_ops_notify "Mac-Ops Cleanup Completed" "$message"
}
