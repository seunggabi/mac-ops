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
# Args: cleaned_count, cleaned_bytes, killed_procs, disk_before_pct (optional), disk_after_pct (optional)
# Do not notify if no items were cleaned (count is 0)
mac_ops_notify_completion() {
  local cleaned_count="$1"
  local cleaned_bytes="$2"
  local killed_procs="$3"
  local disk_before_pct="${4:-}"
  local disk_after_pct="${5:-}"
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

  if [[ -n "$disk_before_pct" && -n "$disk_after_pct" && "$disk_before_pct" != "$disk_after_pct" ]]; then
    local disk_change=$((disk_before_pct - disk_after_pct))
    if (( disk_change > 0 )); then
      message_parts+=("Disk: ${disk_before_pct}% → ${disk_after_pct}% (${disk_change}% freed)")
    else
      message_parts+=("Disk: ${disk_before_pct}% → ${disk_after_pct}%")
    fi
  fi

  # Join message parts
  # shellcheck disable=SC2296
  message="${(j:, :)message_parts}"

  # Send notification
  mac_ops_notify "Mac-Ops Cleanup Completed" "$message"
}
