# =============================================================================
# mac-ops: Prevent duplicate execution
# Block concurrent execution with PID-based lock file, automatic stale lock detection
# =============================================================================

# -----------------------------------------------------------------------------
# Acquire lock
# Return 1 if already running, stale locks are automatically removed and reacquired
# -----------------------------------------------------------------------------
mac_ops_acquire_lock() {
  # If lock file already exists
  if [[ -f "${MAC_OPS_LOCK_FILE}" ]]; then
    local existing_pid
    existing_pid=$(cat "${MAC_OPS_LOCK_FILE}" 2>/dev/null)

    # Check if PID is a valid number
    if [[ -n "${existing_pid}" && "${existing_pid}" =~ ^[0-9]+$ ]]; then
      # Check if process is still alive
      if kill -0 "${existing_pid}" 2>/dev/null; then
        mac_ops_log_error "Already running (PID: ${existing_pid})"
        return 1
      else
        # stale lock detected - process is dead, removing
        mac_ops_log_warn "stale lock detected (PID: ${existing_pid}), removing and reacquiring"
        rm -f "${MAC_OPS_LOCK_FILE}"
      fi
    else
      # Invalid lock file with invalid PID - removing
      mac_ops_log_warn "Invalid lock file detected, removing"
      rm -f "${MAC_OPS_LOCK_FILE}"
    fi
  fi

  # Atomic lock creation using noclobber (prevents TOCTOU race condition)
  # If another process created the file between the check above and here, this will fail safely
  if ! ( set -o noclobber; print -- "$$" > "${MAC_OPS_LOCK_FILE}" ) 2>/dev/null; then
    mac_ops_log_error "Failed to create lock file (another process may have started): ${MAC_OPS_LOCK_FILE}"
    return 1
  fi

  mac_ops_log_debug "Lock acquired (PID: $$)"
  return 0
}

# -----------------------------------------------------------------------------
# Release lock
# -----------------------------------------------------------------------------
mac_ops_release_lock() {
  if [[ -f "${MAC_OPS_LOCK_FILE}" ]]; then
    local lock_pid
    lock_pid=$(cat "${MAC_OPS_LOCK_FILE}" 2>/dev/null)

    # Only release own lock (do not touch other process's lock)
    if [[ "${lock_pid}" == "$$" ]]; then
      rm -f "${MAC_OPS_LOCK_FILE}"
      mac_ops_log_debug "Lock released (PID: $$)"
    else
      mac_ops_log_warn "Lock belongs to another process (PID: ${lock_pid}), not releasing"
    fi
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Set up signal trap
# Register cleanup function for SIGTERM, SIGINT, SIGHUP, EXIT
# -----------------------------------------------------------------------------
mac_ops_setup_trap() {
  trap '_mac_ops_cleanup_on_signal' TERM INT HUP EXIT
}

# -----------------------------------------------------------------------------
# Cleanup function on signal reception (internal)
# Release lock + log ongoing work
# -----------------------------------------------------------------------------
_mac_ops_cleanup_on_signal() {
  # Prevent duplicate execution (EXIT trap also fires after other signals)
  if [[ "${_MAC_OPS_CLEANUP_DONE:-false}" == "true" ]]; then
    return 0
  fi
  _MAC_OPS_CLEANUP_DONE=true

  mac_ops_log_warn "Signal received: starting cleanup (PID: $$)"

  # Release lock
  mac_ops_release_lock

  mac_ops_log_info "Cleanup completed"
}
