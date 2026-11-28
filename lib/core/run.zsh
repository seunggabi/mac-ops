# =============================================================================
# mac-ops: Run lifecycle
# Run ID and the end-of-run bookkeeping (lock release, notification) that has
# to happen exactly once on every exit path: normal end, early return,
# ERR_EXIT abort and INT/TERM/HUP.
# =============================================================================

# sysparams[pid]: real PID of a subshell ($$ stays the parent PID in subshells)
zmodload zsh/system 2>/dev/null || true

typeset -g MAC_OPS_RUN_ID=""
typeset -g MAC_OPS_RUN_STARTED=""
typeset -g MAC_OPS_RUN_LOG_START=0
typeset -g MAC_OPS_RUN_STATS_DIR=""
# "" (no run), "active" (finish pending) or "done"
typeset -g _MAC_OPS_RUN_STATE=""
# true while this process holds the run lock
typeset -g _MAC_OPS_RUN_LOCKED=false

# -----------------------------------------------------------------------------
# Start a run: run ID (<local time>-<PID>), start time, log position (ERROR
# and WARN lines after it are counted for the end-of-run notification).
# -----------------------------------------------------------------------------
mac_ops_run_start() {
  MAC_OPS_RUN_ID="$(date '+%Y%m%dT%H%M%S')-$$"
  MAC_OPS_RUN_STARTED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  _MAC_OPS_RUN_STATE="active"
  _MAC_OPS_RUN_LOCKED=false
  mac_ops_log_line_count; MAC_OPS_RUN_LOG_START="${REPLY}"
  return 0
}

# -----------------------------------------------------------------------------
# Finish the run once: remove the statistics directory, release the run lock
# if this process holds it, notify (scheduled runs; a failed run always).
# Later calls do nothing.
# Usage: mac_ops_run_finish <exit_status> [free_before_bytes] [free_after_bytes]
# -----------------------------------------------------------------------------
mac_ops_run_finish() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  [[ "${_MAC_OPS_RUN_STATE}" == "active" ]] || return 0
  _MAC_OPS_RUN_STATE="done"
  local exit_status="${1:-1}"

  # Guard: only the expected statistics directory pattern is removed
  if [[ -n "${MAC_OPS_RUN_STATS_DIR}" && "${MAC_OPS_RUN_STATS_DIR}" == *"/stats_"* ]]; then
    rm -rf -- "${MAC_OPS_RUN_STATS_DIR}" 2>/dev/null
  fi
  MAC_OPS_RUN_STATS_DIR=""

  if [[ "${_MAC_OPS_RUN_LOCKED}" == "true" ]]; then
    mac_ops_release_lock
    _MAC_OPS_RUN_LOCKED=false
  fi

  mac_ops_notify_run_end "${MAC_OPS_RUN_LOG_START}" "${exit_status}" "${2:-}" "${3:-}"
  return 0
}

# -----------------------------------------------------------------------------
# A run that did not reach its normal end: log it and finish with a non-zero
# status. Only the main shell acts (module subshells inherit the traps).
# Usage: _mac_ops_run_abort <exit_status> <what happened>
# -----------------------------------------------------------------------------
_mac_ops_run_abort() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  [[ "${_MAC_OPS_RUN_STATE}" == "active" ]] || return 0
  [[ "${sysparams[pid]:-$$}" == "$$" ]] || return 0
  local exit_status="${1}"
  [[ "${exit_status}" =~ ^[0-9]+$ && "${exit_status}" -ne 0 ]] || exit_status=1
  mac_ops_log_error "Run aborted (${2}, exit status ${exit_status}): releasing the lock"
  mac_ops_run_finish "${exit_status}"
  return 0
}

# -----------------------------------------------------------------------------
# INT/TERM/HUP: finish the run and exit with 128 + signal number. A module
# subshell only exits (the main shell finishes the run).
# Usage: _mac_ops_on_signal <name> <exit_status>
# -----------------------------------------------------------------------------
_mac_ops_on_signal() {
  if [[ "${sysparams[pid]:-$$}" == "$$" ]]; then
    _mac_ops_run_abort "${2}" "signal ${1}"
  fi
  exit "${2}"
}

# -----------------------------------------------------------------------------
# ZERR: under ERR_EXIT the main shell is about to exit. zsh runs neither an
# EXIT trap nor zshexit when ERR_EXIT ends the shell inside a function, so
# this is the only place a failed command can still finish the run.
# ZERR also fires in NO_ERR_EXIT functions and in subshells: ignored there.
# Usage: _mac_ops_on_zerr <status>
# -----------------------------------------------------------------------------
_mac_ops_on_zerr() {
  [[ -o errexit && "${sysparams[pid]:-$$}" == "$$" ]] || return 0
  _mac_ops_run_abort "${1}" "command failed"
  return 0
}

# -----------------------------------------------------------------------------
# zshexit hook: an explicit exit while the run is still active
# -----------------------------------------------------------------------------
_mac_ops_on_exit() {
  local exit_status=$?
  _mac_ops_run_abort "${exit_status}" "exited early"
  return 0
}
