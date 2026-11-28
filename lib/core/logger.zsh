# =============================================================================
# mac-ops: Logging system
# Simultaneous file + stdout output, log level support, rotation
# =============================================================================

# Log file path
MAC_OPS_LOG_FILE="${MAC_OPS_LOG_DIR}/mac-ops.log"

# Log level constants
typeset -A MAC_OPS_LOG_LEVELS
# shellcheck disable=SC2190
MAC_OPS_LOG_LEVELS=(
  DEBUG 0
  INFO  1
  WARN  2
  ERROR 3
)

# Log rotation settings
MAC_OPS_LOG_MAX_SIZE=5242880   # 5MB
MAC_OPS_LOG_MAX_FILES=7        # Keep maximum 7 files

# -----------------------------------------------------------------------------
# Core log function
# Usage: mac_ops_log <LEVEL> <message>
# -----------------------------------------------------------------------------
mac_ops_log() {
  local level="${1}"
  local message="${2}"

  # Validate level
  if [[ -z "${MAC_OPS_LOG_LEVELS[${level}]+_}" ]]; then
    level="INFO"
  fi

  # DEBUG level only outputs in VERBOSE mode
  if [[ "${level}" == "DEBUG" && "${MAC_OPS_VERBOSE}" != "true" ]]; then
    return 0
  fi

  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local formatted="[${timestamp}] [${level}] ${message}"

  # File output (if log directory exists)
  if [[ -d "${MAC_OPS_LOG_DIR}" ]]; then
    # If log file is newly created, set to be readable/writable only by owner
    if [[ ! -f "${MAC_OPS_LOG_FILE}" ]]; then
      touch "${MAC_OPS_LOG_FILE}" 2>/dev/null
      chmod 600 "${MAC_OPS_LOG_FILE}" 2>/dev/null
    fi
    print -- "${formatted}" >> "${MAC_OPS_LOG_FILE}" 2>/dev/null
  fi

  # stdout output (only when not in SCHEDULED mode)
  if [[ "${MAC_OPS_SCHEDULED}" != "true" ]]; then
    if [[ "${level}" == "ERROR" || "${level}" == "WARN" ]]; then
      print -- "${formatted}" >&2
    else
      print -- "${formatted}"
    fi
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Shortcut log functions
# -----------------------------------------------------------------------------
mac_ops_log_info() {
  mac_ops_log "INFO" "${1}"
}

mac_ops_log_warn() {
  mac_ops_log "WARN" "${1}"
}

mac_ops_log_error() {
  mac_ops_log "ERROR" "${1}"
}

mac_ops_log_debug() {
  mac_ops_log "DEBUG" "${1}"
}

# -----------------------------------------------------------------------------
# Number of lines in the log file (0 when absent). Result in REPLY.
# -----------------------------------------------------------------------------
mac_ops_log_line_count() {
  REPLY=0
  if [[ -f "${MAC_OPS_LOG_FILE}" ]]; then
    REPLY=$(wc -l < "${MAC_OPS_LOG_FILE}" 2>/dev/null | tr -d ' ') || REPLY=0
  fi
  [[ "${REPLY}" =~ ^[0-9]+$ ]] || REPLY=0
  return 0
}

# -----------------------------------------------------------------------------
# Count log lines of one level written after line <start>. Counted from the
# file so lines from parallel module subshells are included. If the file
# shrank (rotated) since <start>, the whole file is counted. Result in REPLY.
# Usage: mac_ops_log_count_since <start_line> <LEVEL>
# -----------------------------------------------------------------------------
mac_ops_log_count_since() {
  local start="${1:-0}" level="${2}"
  [[ "${start}" =~ ^[0-9]+$ ]] || start=0
  mac_ops_log_line_count
  (( REPLY < start )) && start=0
  REPLY=0
  [[ -f "${MAC_OPS_LOG_FILE}" ]] || return 0
  REPLY=$(tail -n +$((start + 1)) "${MAC_OPS_LOG_FILE}" 2>/dev/null | grep -c "^\[[^]]*\] \[${level}\] " || true)
  [[ "${REPLY}" =~ ^[0-9]+$ ]] || REPLY=0
  return 0
}

# -----------------------------------------------------------------------------
# Log file rotation
# Execute when exceeds 5MB, keep maximum 7 files
# mac-ops.log -> mac-ops.log.1 -> ... -> mac-ops.log.7 (deleted)
# -----------------------------------------------------------------------------
mac_ops_log_rotate() {
  # Nothing to do if log file does not exist
  if [[ ! -f "${MAC_OPS_LOG_FILE}" ]]; then
    return 0
  fi

  # Check current log file size (bytes)
  local file_size
  file_size=$(stat -f%z "${MAC_OPS_LOG_FILE}" 2>/dev/null || echo 0)

  # No rotation needed if 5MB or less
  if [[ ${file_size} -le ${MAC_OPS_LOG_MAX_SIZE} ]]; then
    return 0
  fi

  # Delete oldest log (exceeding maximum retention)
  local i=${MAC_OPS_LOG_MAX_FILES}
  if [[ -f "${MAC_OPS_LOG_FILE}.${i}" ]]; then
    rm -f "${MAC_OPS_LOG_FILE}.${i}"
  fi

  # Increase existing log file numbers (in reverse order)
  i=$((MAC_OPS_LOG_MAX_FILES - 1))
  while [[ ${i} -ge 1 ]]; do
    if [[ -f "${MAC_OPS_LOG_FILE}.${i}" ]]; then
      mv "${MAC_OPS_LOG_FILE}.${i}" "${MAC_OPS_LOG_FILE}.$((i + 1))"
    fi
    i=$((i - 1))
  done

  # Move current log to .1
  mv "${MAC_OPS_LOG_FILE}" "${MAC_OPS_LOG_FILE}.1"

  # Create new log file (readable/writable only by owner)
  touch "${MAC_OPS_LOG_FILE}"
  chmod 600 "${MAC_OPS_LOG_FILE}"

  return 0
}
