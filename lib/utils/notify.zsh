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
# Args: same as mac_ops_notify_message, then [failure fingerprint]
# A failed run (errors logged or non-zero exit status) is notified in
# scheduled and manual mode alike, but the same failure (same fingerprint,
# see mac_ops_notify_run_end) at most once per MAC_OPS_NOTIFY_REPEAT_HOURS
# (setting Notify.FailureRepeatHours, default 24). A successful run is
# notified only in scheduled mode and only when MAC_OPS_NOTIFY_ON_SUCCESS is
# true (setting Notify.OnSuccess, default false).
mac_ops_notify_completion() {
  local message title="Mac-Ops Cleanup Completed"
  message=$(mac_ops_notify_message "${@:1:9}")
  [[ -z "$message" ]] && return 0
  if [[ "${7:-0}" != "0" || "${9:-0}" != "0" ]]; then
    local fingerprint="${10:-${message}}"
    if _mac_ops_notify_failure_recent "${fingerprint}"; then
      (( ${+functions[mac_ops_log_info]} )) && \
        mac_ops_log_info "Failure notification not repeated: the same failure was notified within the last ${MAC_OPS_NOTIFY_REPEAT_HOURS:-24}h"
      return 0
    fi
    mac_ops_notify "Mac-Ops Run Had Errors" "$message" "always"
    _mac_ops_notify_failure_record "${fingerprint}"
    return 0
  fi
  [[ "${MAC_OPS_NOTIFY_ON_SUCCESS:-false}" == "true" ]] || return 0
  mac_ops_notify "$title" "$message"
}

# -----------------------------------------------------------------------------
# Failure notification state: one line "<epoch> <sha256 of the fingerprint>"
# in ${MAC_OPS_HOME}/.notify-failure.state. A missing, unreadable or corrupt
# file means "not notified recently" (notify).
# -----------------------------------------------------------------------------
_mac_ops_notify_state_file() {
  REPLY="${MAC_OPS_HOME:-${HOME}/.mac-ops}/.notify-failure.state"
}

_mac_ops_notify_hash() {
  REPLY=$(print -rn -- "${1}" | shasum -a 256 2>/dev/null) || REPLY=""
  REPLY="${REPLY%% *}"
}

# Return 0 when this fingerprint was notified less than the repeat interval ago
_mac_ops_notify_failure_recent() {
  local hours="${MAC_OPS_NOTIFY_REPEAT_HOURS:-24}" line epoch hash now
  [[ "${hours}" =~ ^[0-9]+$ && "${hours}" -gt 0 ]] || hours=24
  _mac_ops_notify_state_file
  [[ -f "${REPLY}" ]] || return 1
  line=$(head -n 1 -- "${REPLY}" 2>/dev/null) || return 1
  epoch="${line%% *}"; hash="${line#* }"
  [[ "${epoch}" =~ ^[0-9]+$ && "${hash}" =~ ^[0-9a-f]{64}$ ]] || return 1
  _mac_ops_notify_hash "${1}"
  [[ -n "${REPLY}" && "${REPLY}" == "${hash}" ]] || return 1
  now=$(date +%s)
  (( now >= epoch && now - epoch < hours * 3600 ))
}

# Record a notified failure (atomic: temp file in the same directory, rename)
_mac_ops_notify_failure_record() {
  local file tmp hash
  _mac_ops_notify_state_file; file="${REPLY}"
  _mac_ops_notify_hash "${1}"; hash="${REPLY}"
  [[ -n "${hash}" && -d "${file:h}" ]] || return 0
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
  if print -r -- "$(date +%s) ${hash}" > "${tmp}" 2>/dev/null && mv -f -- "${tmp}" "${file}" 2>/dev/null; then
    return 0
  fi
  rm -f -- "${tmp}" 2>/dev/null
  return 0
}

# End-of-run notification: counts ERROR/WARN lines written to the log since
# line <log_start> (parallel modules included) and notifies; a run that
# failed is notified even when nothing was cleaned.
# The failure fingerprint is the exit status plus the distinct ERROR
# messages of this run (timestamps removed), so the same failure every hour
# is notified once per repeat interval and a new failure at once.
# Args: log_start, exit_status, free_before_bytes (optional), free_after_bytes (optional)
# Uses MAC_OPS_CLEANED_COUNT, MAC_OPS_CLEANED_BYTES, MAC_OPS_KILLED_COUNT,
# MAC_OPS_DATA_MOVED_COUNT.
mac_ops_notify_run_end() {
  local log_start="$1" exit_status="${2:-0}" errors warnings fingerprint=""
  mac_ops_log_count_since "${log_start}" ERROR; errors="${REPLY}"
  mac_ops_log_count_since "${log_start}" WARN; warnings="${REPLY}"
  if [[ "${errors}" != "0" || "${exit_status}" != "0" ]]; then
    local start="${log_start}"
    [[ "${start}" =~ ^[0-9]+$ ]] || start=0
    mac_ops_log_line_count
    (( REPLY < start )) && start=0
    fingerprint="exit=${exit_status}"$'\n'
    if [[ -f "${MAC_OPS_LOG_FILE}" ]]; then
      fingerprint+=$(tail -n +$((start + 1)) "${MAC_OPS_LOG_FILE}" 2>/dev/null \
        | sed -n 's/^\[[^]]*\] \[ERROR\] //p' | sort -u)
    fi
  fi
  mac_ops_notify_completion "${MAC_OPS_CLEANED_COUNT:-0}" "${MAC_OPS_CLEANED_BYTES:-0}" \
    "${MAC_OPS_KILLED_COUNT:-0}" "${3:-}" "${4:-}" "${MAC_OPS_DATA_MOVED_COUNT:-0}" \
    "${errors}" "${warnings}" "${exit_status}" "${fingerprint}"
}
