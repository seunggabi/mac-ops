# =============================================================================
# mac-ops: Prevent duplicate execution
# The run lock is MAC_OPS_LOCK_FILE holding "<pid> <process start epoch>".
# A lock whose PID is gone, or whose PID now belongs to a process started at
# another time (PID reuse), is stale. Check, stale clear and create happen
# under a short "zsystem flock" on MAC_OPS_LOCK_FILE.guard, so two runs can
# never both clear a stale lock and both win.
# =============================================================================
# zsh-only parameter flags; false positives in bash mode
# shellcheck disable=SC2296

# zsystem flock, sysparams[pid] (real PID; $$ stays the parent PID in subshells)
zmodload zsh/system 2>/dev/null || true

# Seconds to wait for the guard (it is only held for a few milliseconds)
typeset -gi MAC_OPS_LOCK_GUARD_TIMEOUT_SECONDS=${MAC_OPS_LOCK_GUARD_TIMEOUT_SECONDS:-10}

# -----------------------------------------------------------------------------
# Start time of a running process as epoch seconds in REPLY ("" when the
# process does not exist). The C locale keeps ps and date output comparable
# between an interactive shell and launchd.
# Usage: _mac_ops_lock_pid_start <pid>
# -----------------------------------------------------------------------------
_mac_ops_lock_pid_start() {
  REPLY=""
  [[ "${1}" =~ ^[0-9]+$ ]] || return 1
  local lstart
  lstart=$(LC_ALL=C ps -o lstart= -p "${1}" 2>/dev/null) || return 1
  local -a words=(${=lstart})
  (( ${#words} == 5 )) || return 1
  REPLY=$(LC_ALL=C date -j -f "%a %b %d %T %Y" "${words[*]}" +%s 2>/dev/null) || { REPLY=""; return 1; }
  [[ "${REPLY}" =~ ^[0-9]+$ ]] || { REPLY=""; return 1; }
  return 0
}

# -----------------------------------------------------------------------------
# Is the existing lock file held by a live run? Returns 0 when live; the PID
# is in REPLY. Legacy content (PID only): live when the process started
# before the lock file was last written.
# -----------------------------------------------------------------------------
_mac_ops_lock_is_live() {
  local content pid recorded mtime
  content=$(cat -- "${MAC_OPS_LOCK_FILE}" 2>/dev/null) || content=""
  local -a fields=(${=content})
  pid="${fields[1]:-}" recorded="${fields[2]:-}"
  REPLY="${pid}"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  [[ -z "${recorded}" || "${recorded}" =~ ^[0-9]+$ ]] || return 1
  local holder="${REPLY}"
  _mac_ops_lock_pid_start "${pid}" || { REPLY="${holder}"; return 1; }
  local started="${REPLY}"
  REPLY="${holder}"
  if [[ -n "${recorded}" ]]; then
    [[ "${started}" == "${recorded}" ]]
    return
  fi
  mtime=$(stat -f %m -- "${MAC_OPS_LOCK_FILE}" 2>/dev/null) || return 0
  [[ "${mtime}" =~ ^[0-9]+$ ]] || return 0
  (( started <= mtime ))
}

# -----------------------------------------------------------------------------
# Acquire the run lock
# Returns 0 when acquired, 1 when another live run holds it, 2 when the lock
# cannot be checked or created (an error). A stale lock is removed.
# -----------------------------------------------------------------------------
mac_ops_acquire_lock() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  local self_pid="${sysparams[pid]:-$$}"
  local guard="${MAC_OPS_LOCK_FILE}.guard"

  if ! zsystem supports flock 2>/dev/null; then
    mac_ops_log_error "Run lock unavailable: zsh/system 'zsystem flock' is not supported by this zsh"
    return 2
  fi
  if [[ ! -f "${guard}" ]] && ! { : >> "${guard}"; } 2>/dev/null; then
    mac_ops_log_error "Run lock unavailable: cannot create ${guard}"
    return 2
  fi
  local guard_fd=""
  if ! zsystem flock -t "${MAC_OPS_LOCK_GUARD_TIMEOUT_SECONDS}" -i 0.1 -f guard_fd "${guard}" 2>/dev/null; then
    mac_ops_log_error "Run lock unavailable: timeout waiting for ${guard}"
    return 2
  fi

  local rc=0
  if [[ -e "${MAC_OPS_LOCK_FILE}" || -L "${MAC_OPS_LOCK_FILE}" ]]; then
    if _mac_ops_lock_is_live; then
      mac_ops_log_info "Another mac-ops run is in progress (PID: ${REPLY})"
      rc=1
    else
      mac_ops_log_warn "Stale run lock (PID: ${REPLY:-none}, process gone or PID reused), removing"
      rm -f -- "${MAC_OPS_LOCK_FILE}" 2>/dev/null
    fi
  fi

  if (( rc == 0 )); then
    local started=""
    _mac_ops_lock_pid_start "${self_pid}" && started="${REPLY}"
    if [[ -z "${started}" ]]; then
      mac_ops_log_error "Run lock unavailable: cannot read the start time of PID ${self_pid}"
      rc=2
    elif ! ( set -o noclobber; print -r -- "${self_pid} ${started}" > "${MAC_OPS_LOCK_FILE}" ) 2>/dev/null; then
      mac_ops_log_error "Failed to create the run lock: ${MAC_OPS_LOCK_FILE}"
      rc=2
    else
      mac_ops_log_debug "Lock acquired (PID: ${self_pid})"
    fi
  fi

  zsystem flock -u "${guard_fd}" 2>/dev/null || true
  return "${rc}"
}

# -----------------------------------------------------------------------------
# Release the run lock: only when this process (not a subshell of it, not
# another run) holds it
# -----------------------------------------------------------------------------
mac_ops_release_lock() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  local self_pid="${sysparams[pid]:-$$}"
  [[ -e "${MAC_OPS_LOCK_FILE}" ]] || return 0
  local content
  content=$(cat -- "${MAC_OPS_LOCK_FILE}" 2>/dev/null) || content=""
  local -a fields=(${=content})
  if [[ "${fields[1]:-}" == "${self_pid}" ]]; then
    rm -f -- "${MAC_OPS_LOCK_FILE}"
    mac_ops_log_debug "Lock released (PID: ${self_pid})"
  else
    mac_ops_log_warn "Lock belongs to another process (PID: ${fields[1]:-none}), not releasing"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Set up the run's exit handling (handlers in run.zsh)
# A "trap ... EXIT" set inside a function fires when that function returns,
# which released the lock right after it was taken. Signal and ZERR traps
# set here stay global; an explicit exit is caught by the zshexit hook and an
# ERR_EXIT abort by ZERR (zsh runs no EXIT trap or zshexit in that case).
# -----------------------------------------------------------------------------
mac_ops_setup_trap() {
  trap '_mac_ops_on_signal HUP 129' HUP
  trap '_mac_ops_on_signal INT 130' INT
  trap '_mac_ops_on_signal TERM 143' TERM
  trap '_mac_ops_on_zerr $?' ZERR
  if [[ "${zshexit_functions[(Ie)_mac_ops_on_exit]:-0}" == "0" ]]; then
    zshexit_functions+=(_mac_ops_on_exit)
  fi
}
