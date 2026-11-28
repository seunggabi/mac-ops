# =============================================================================
# mac-ops: Run lifecycle
# Run ID and the end-of-run bookkeeping (manifest, lock release,
# notification) that has to happen exactly once on every exit path: normal
# end, early return, ERR_EXIT abort and INT/TERM/HUP.
# Run manifests (${MAC_OPS_HOME}/runs/<run-id>.json), "mac-ops runs" and
# "mac-ops restore --run <run-id>".
# =============================================================================
# zsh-only parameter flags and glob qualifiers; false positives in bash mode
# shellcheck disable=SC2296,SC1036,SC1072,SC1073,SC1058

# sysparams[pid]: real PID of a subshell ($$ stays the parent PID in subshells)
zmodload zsh/system 2>/dev/null || true

typeset -g MAC_OPS_RUN_ID=""
typeset -g MAC_OPS_RUN_STARTED=""
typeset -g MAC_OPS_RUN_LOG_START=0
typeset -g MAC_OPS_RUN_STATS_DIR=""
# Per-run move list (one line per move, see _mac_ops_trash_note_run_move)
typeset -g MAC_OPS_RUN_MOVES_FILE=""
typeset -g MAC_OPS_RUN_FREE_KB_BEFORE=""
# Newest manifests kept in ${MAC_OPS_HOME}/runs
typeset -gi MAC_OPS_RUNS_KEEP=${MAC_OPS_RUNS_KEEP:-200}
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
  _mac_ops_trash_volume_free_kb; MAC_OPS_RUN_FREE_KB_BEFORE="${REPLY}"

  # Dry-run: no move list and no manifest
  MAC_OPS_RUN_MOVES_FILE=""
  if [[ "${MAC_OPS_DRY_RUN}" != "true" ]]; then
    local moves="${MAC_OPS_HOME}/.tmp/run_${MAC_OPS_RUN_ID}.moves"
    if mkdir -p "${moves:h}" 2>/dev/null && : > "${moves}" 2>/dev/null; then
      MAC_OPS_RUN_MOVES_FILE="${moves}"
    else
      mac_ops_log_warn "Cannot create the run move list, the manifest lists no moves: ${moves}"
    fi
  fi
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

  _mac_ops_run_write_manifest "${exit_status}"
  # The move list is removed whether or not a manifest was written (dry-run
  # set by the configuration after the run started, write failure)
  if [[ -n "${MAC_OPS_RUN_MOVES_FILE}" && "${MAC_OPS_RUN_MOVES_FILE}" == *"/run_"*".moves" ]]; then
    rm -f "${MAC_OPS_RUN_MOVES_FILE}" 2>/dev/null
  fi
  MAC_OPS_RUN_MOVES_FILE=""

  if [[ "${_MAC_OPS_RUN_LOCKED}" == "true" ]]; then
    mac_ops_release_lock
    _MAC_OPS_RUN_LOCKED=false
  fi

  mac_ops_notify_run_end "${MAC_OPS_RUN_LOG_START}" "${exit_status}" "${2:-}" "${3:-}"
  return 0
}

# -----------------------------------------------------------------------------
# Drop a run that never took the lock (another run holds it): no manifest,
# no notification, move list removed. The exit hooks do nothing afterwards.
# -----------------------------------------------------------------------------
mac_ops_run_discard() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  [[ "${_MAC_OPS_RUN_STATE}" == "active" ]] || return 0
  _MAC_OPS_RUN_STATE="done"
  if [[ -n "${MAC_OPS_RUN_MOVES_FILE}" && "${MAC_OPS_RUN_MOVES_FILE}" == *"/run_"*".moves" ]]; then
    rm -f "${MAC_OPS_RUN_MOVES_FILE}" 2>/dev/null
  fi
  MAC_OPS_RUN_MOVES_FILE=""
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

# =============================================================================
# Run manifest
# =============================================================================

# -----------------------------------------------------------------------------
# Is this a run ID (<YYYYmmdd>T<HHMMSS>-<pid>)? Guards every manifest path.
# -----------------------------------------------------------------------------
_mac_ops_run_id_valid() {
  [[ "${1}" =~ ^[0-9]{8}T[0-9]{6}-[0-9]+$ ]]
}

# -----------------------------------------------------------------------------
# Write ${MAC_OPS_HOME}/runs/<run-id>.json from the move list (atomic rename),
# remove the move list and keep the newest MAC_OPS_RUNS_KEEP manifests.
# Nothing is written in dry-run.
# Usage: _mac_ops_run_write_manifest <exit_status>
# -----------------------------------------------------------------------------
_mac_ops_run_write_manifest() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  [[ "${MAC_OPS_DRY_RUN}" == "true" ]] && return 0
  _mac_ops_run_id_valid "${MAC_OPS_RUN_ID}" || return 0

  local runs_dir="${MAC_OPS_HOME}/runs"
  local manifest="${runs_dir}/${MAC_OPS_RUN_ID}.json"
  local errors warnings free_after ended
  mac_ops_log_count_since "${MAC_OPS_RUN_LOG_START}" ERROR; errors="${REPLY}"
  mac_ops_log_count_since "${MAC_OPS_RUN_LOG_START}" WARN; warnings="${REPLY}"
  _mac_ops_trash_volume_free_kb; free_after="${REPLY}"
  ended="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Moves and per-module counts from the move list
  local -a move_lines
  local -A mod_items mod_bytes mod_data
  local line e_mod size data e_orig e_trash e_reason
  local items=0 data_items=0 bytes=0
  move_lines=()
  if [[ -n "${MAC_OPS_RUN_MOVES_FILE}" && -f "${MAC_OPS_RUN_MOVES_FILE}" ]]; then
    while IFS=$'\t' read -r e_mod size data e_orig e_trash e_reason; do
      [[ -n "${e_trash}" ]] || continue
      [[ "${size}" =~ ^[0-9]+$ ]] || size=0
      [[ "${data}" == "1" ]] || data=0
      items=$((items + 1))
      bytes=$((bytes + size))
      data_items=$((data_items + data))
      mod_items[${e_mod}]=$(( ${mod_items[${e_mod}]:-0} + 1 ))
      mod_bytes[${e_mod}]=$(( ${mod_bytes[${e_mod}]:-0} + size ))
      mod_data[${e_mod}]=$(( ${mod_data[${e_mod}]:-0} + data ))
      line="    {\"module\": \"${e_mod}\", \"original_path\": \"${e_orig}\", \"trash_path\": \"${e_trash}\", \"reason\": \"${e_reason}\", \"size_bytes\": ${size}, \"data\": $([[ ${data} -eq 1 ]] && print true || print false)}"
      move_lines+=("${line}")
    done < "${MAC_OPS_RUN_MOVES_FILE}"
  fi

  if ! mkdir -p "${runs_dir}" 2>/dev/null; then
    mac_ops_log_error "Run manifest not written (cannot create ${runs_dir})"
    return 1
  fi
  local tmp_file=""
  tmp_file=$(mktemp "${runs_dir}/.${MAC_OPS_RUN_ID}.json.XXXXXX" 2>/dev/null) || tmp_file=""
  if [[ -z "${tmp_file}" ]]; then
    mac_ops_log_error "Run manifest not written (cannot create a temp file in ${runs_dir})"
    return 1
  fi

  local write_ok=true mod first=true i
  {
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "run_id": "%s",\n' "${MAC_OPS_RUN_ID}"
    printf '  "scheduled": %s,\n' "$([[ "${MAC_OPS_SCHEDULED}" == "true" ]] && print true || print false)"
    printf '  "started": "%s",\n' "${MAC_OPS_RUN_STARTED}"
    printf '  "ended": "%s",\n' "${ended}"
    printf '  "exit_status": %d,\n' "${1:-1}"
    printf '  "errors": %d,\n' "${errors:-0}"
    printf '  "warnings": %d,\n' "${warnings:-0}"
    printf '  "items_moved": %d,\n' "${items}"
    printf '  "data_items_moved": %d,\n' "${data_items}"
    printf '  "bytes_moved": %d,\n' "${bytes}"
    printf '  "cleaned_items": %d,\n' "${MAC_OPS_CLEANED_COUNT:-0}"
    printf '  "killed_processes": %d,\n' "${MAC_OPS_KILLED_COUNT:-0}"
    printf '  "free_kb_before": %s,\n' "${MAC_OPS_RUN_FREE_KB_BEFORE:-null}"
    printf '  "free_kb_after": %s,\n' "${free_after:-null}"
    printf '  "modules": {'
    for mod in ${(ko)mod_items}; do
      [[ "${first}" == true ]] && first=false || printf ','
      printf '\n    "%s": {"items": %d, "bytes": %d, "data_items": %d}' \
        "${mod}" "${mod_items[${mod}]}" "${mod_bytes[${mod}]}" "${mod_data[${mod}]}"
    done
    [[ "${first}" == true ]] && printf '},\n' || printf '\n  },\n'
    printf '  "moves": ['
    for (( i = 1; i <= ${#move_lines}; i++ )); do
      printf '\n%s' "${move_lines[i]}"
      (( i < ${#move_lines} )) && printf ','
    done
    [[ ${#move_lines} -eq 0 ]] && printf ']\n' || printf '\n  ]\n'
    printf '}\n' || write_ok=false
  } > "${tmp_file}" 2>/dev/null || write_ok=false

  if [[ "${write_ok}" != true ]] || ! mv -f "${tmp_file}" "${manifest}" 2>/dev/null; then
    rm -f "${tmp_file}" 2>/dev/null
    mac_ops_log_error "Run manifest not written: ${manifest}"
    return 1
  fi

  # Keep the newest manifests (run IDs sort by start time)
  local -a manifests
  manifests=("${runs_dir}"/*.json(N))
  if (( ${#manifests} > MAC_OPS_RUNS_KEEP )); then
    rm -f -- "${manifests[@]:0:$(( ${#manifests} - MAC_OPS_RUNS_KEEP ))}" 2>/dev/null
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Read the summary fields of a manifest into the global associative array
# MAC_OPS_MANIFEST (run_id, scheduled, started, ended, exit_status, errors,
# warnings, items_moved, data_items_moved, bytes_moved). Read-only.
# Usage: mac_ops_run_manifest_read <file>
# -----------------------------------------------------------------------------
typeset -gA MAC_OPS_MANIFEST
mac_ops_run_manifest_read() {
  MAC_OPS_MANIFEST=()
  [[ -f "${1}" ]] || return 1
  local line trimmed key
  while IFS= read -r line || [[ -n "${line}" ]]; do
    trimmed="${line#"${line%%[! ]*}"}"
    [[ "${trimmed}" == '"modules":'* ]] && break
    case "${trimmed}" in
      '"run_id":'*|'"started":'*|'"ended":'*)
        key="${trimmed#\"}"; key="${key%%\"*}"
        _mac_ops_json_extract_string "${trimmed}"
        MAC_OPS_MANIFEST[${key}]="${REPLY}"
        ;;
      '"scheduled":'*)
        [[ "${trimmed}" == *true* ]] && MAC_OPS_MANIFEST[scheduled]=true || MAC_OPS_MANIFEST[scheduled]=false
        ;;
      '"exit_status":'*|'"errors":'*|'"warnings":'*|'"items_moved":'*|'"data_items_moved":'*|'"bytes_moved":'*)
        key="${trimmed#\"}"; key="${key%%\"*}"
        _mac_ops_json_extract_number "${trimmed}"
        MAC_OPS_MANIFEST[${key}]="${REPLY}"
        ;;
    esac
  done < "${1}"
  [[ -n "${MAC_OPS_MANIFEST[run_id]}" ]]
}

# -----------------------------------------------------------------------------
# Manifest files, oldest first. Result in reply.
# -----------------------------------------------------------------------------
_mac_ops_run_manifests() {
  reply=("${MAC_OPS_HOME}/runs"/*.json(N))
  return 0
}

# -----------------------------------------------------------------------------
# List recent runs (newest first). Read-only.
# Usage: mac_ops_runs_list [count]
# -----------------------------------------------------------------------------
mac_ops_runs_list() {
  local count="${1:-20}"
  [[ "${count}" =~ ^[0-9]+$ && "${count}" -gt 0 ]] || count=20
  _mac_ops_run_manifests
  local -a files
  files=("${reply[@]}")
  if [[ ${#files} -eq 0 ]]; then
    print "No runs recorded in ${MAC_OPS_HOME}/runs"
    return 0
  fi

  local i f st shown=0
  printf '%-24s %-21s %-12s %7s %6s %6s %6s\n' "RUN ID" "STARTED (UTC)" "STATUS" "ITEMS" "DATA" "ERRORS" "WARNS"
  for (( i = ${#files}; i >= 1 && shown < count; i-- )); do
    f="${files[i]}"
    mac_ops_run_manifest_read "${f}" || continue
    st="ok"
    [[ "${MAC_OPS_MANIFEST[exit_status]:-1}" != "0" ]] && st="failed(${MAC_OPS_MANIFEST[exit_status]:-?})"
    printf '%-24s %-21s %-12s %7s %6s %6s %6s\n' "${MAC_OPS_MANIFEST[run_id]}" \
      "${MAC_OPS_MANIFEST[started]}" "${st}" "${MAC_OPS_MANIFEST[items_moved]:-0}" \
      "${MAC_OPS_MANIFEST[data_items_moved]:-0}" "${MAC_OPS_MANIFEST[errors]:-0}" \
      "${MAC_OPS_MANIFEST[warnings]:-0}"
    shown=$((shown + 1))
  done
  return 0
}

# -----------------------------------------------------------------------------
# Restore every item of a run that is still in the trash (index records with
# that run_id), each through the single-item restore. An item whose original
# location exists again is refused. Honours dry-run.
# Returns 1 when any item was refused or failed (or the run is unknown).
# Usage: mac_ops_trash_restore_run <run-id>
# -----------------------------------------------------------------------------
mac_ops_trash_restore_run() {
  local run_id="${1}"
  if ! _mac_ops_run_id_valid "${run_id}"; then
    mac_ops_log_error "Not a run ID: '${run_id}' (see: mac-ops runs)"
    return 1
  fi
  local manifest="${MAC_OPS_HOME}/runs/${run_id}.json"
  if [[ ! -f "${manifest}" ]]; then
    mac_ops_log_error "No manifest for run ${run_id}: ${manifest} (see: mac-ops runs)"
    return 1
  fi
  mac_ops_run_manifest_read "${manifest}" || true
  local recorded="${MAC_OPS_MANIFEST[items_moved]:-0}"

  if ! _mac_ops_index_lock; then
    mac_ops_log_error "Restore skipped (index lock unavailable): run ${run_id}"
    return 1
  fi
  _mac_ops_index_load_locked

  local -a keys
  local key
  keys=()
  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    [[ "${_MAC_OPS_IDX_RUNID[${key}]}" == "${run_id}" ]] && keys+=("${key}")
  done

  # Newest move first: when a run moved X/sub and later X, X is restored
  # before X/sub, so restoring X/sub does not create X and refuse it
  local restored=0 refused=0 failed=0 gone=0 orig
  for key in "${(Oa)keys[@]}"; do
    orig="${_MAC_OPS_IDX_ORIG[${key}]}"
    if _mac_ops_trash_restore_key_locked "${key}"; then
      restored=$((restored + 1))
      if [[ "${REPLY}" == "dry-run" ]]; then
        print -r -- "WOULD RESTORE: ${orig}"
      else
        print -r -- "RESTORED: ${orig}"
      fi
    else
      case "${REPLY}" in
        exists)  refused=$((refused + 1)); print -r -- "REFUSED (destination exists): ${orig}" ;;
        missing) gone=$((gone + 1)); print -r -- "SKIPPED (no longer in the trash): ${orig}" ;;
        *)       failed=$((failed + 1)); print -r -- "FAILED: ${orig}" ;;
      esac
    fi
  done
  _mac_ops_index_unlock

  local not_in_trash=$(( recorded - ${#keys} ))
  (( not_in_trash < 0 )) && not_in_trash=0
  gone=$((gone + not_in_trash))
  local verb="restored"
  [[ "${MAC_OPS_DRY_RUN}" == "true" ]] && verb="would be restored"
  print "Run ${run_id}: ${restored} ${verb}, ${refused} refused, ${failed} failed, ${gone} no longer in the trash"
  mac_ops_log_info "Restore of run ${run_id}: ${restored} ${verb}, ${refused} refused, ${failed} failed, ${gone} no longer in the trash"
  (( refused == 0 && failed == 0 ))
}

# =============================================================================
# Health (mac-ops status)
# =============================================================================

# -----------------------------------------------------------------------------
# Is a launchd agent loaded? Read-only (launchctl list <label>). Tests
# replace this function.
# Usage: _mac_ops_agent_loaded <label>
# -----------------------------------------------------------------------------
_mac_ops_agent_loaded() {
  launchctl list "${1}" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Scheduling interval of an installed agent plist in seconds (REPLY, empty
# when unknown). StartInterval is used as is; for StartCalendarInterval (its
# first entry if it is a list) the interval is the period of the coarsest
# field set: Month 1 year, Day 31 days, Weekday 7 days, Hour 1 day,
# Minute only 1 hour.
# Usage: _mac_ops_agent_interval <plist>
# -----------------------------------------------------------------------------
_mac_ops_agent_interval() {
  local plist="${1}" v base
  REPLY=""
  v=$(plutil -extract StartInterval raw -o - "${plist}" 2>/dev/null) || v=""
  if [[ "${v}" =~ ^[0-9]+$ && "${v}" -gt 0 ]]; then
    REPLY="${v}"
    return 0
  fi
  base="StartCalendarInterval"
  if plutil -extract "${base}.0" xml1 -o - "${plist}" >/dev/null 2>&1; then
    base="${base}.0"
  fi
  plutil -extract "${base}" xml1 -o - "${plist}" >/dev/null 2>&1 || return 0
  local key secs
  for key secs in Month 31536000 Day 2678400 Weekday 604800 Hour 86400 Minute 3600; do
    if plutil -extract "${base}.${key}" raw -o - "${plist}" >/dev/null 2>&1; then
      REPLY="${secs}"
      return 0
    fi
  done
  # A dict with no fields fires every minute
  REPLY=60
  return 0
}

# -----------------------------------------------------------------------------
# "3h", "45m": a duration in seconds for humans. Result in REPLY.
# -----------------------------------------------------------------------------
_mac_ops_run_duration() {
  local s="${1:-0}"
  if (( s >= 172800 )); then REPLY="$(( s / 86400 ))d"
  elif (( s >= 7200 )); then REPLY="$(( s / 3600 ))h"
  else REPLY="$(( s / 60 ))m"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Print the health section of "mac-ops status". Read-only. When the last
# scheduled run failed, the cleanup agent is installed but not loaded, or it
# has not run for more than three intervals, the FIRST line printed is an
# "[ALERT] ..." line saying so.
# Usage: mac_ops_run_health [launch_agents_dir]
# -----------------------------------------------------------------------------
mac_ops_run_health() {
  local agent_dir="${1:-${HOME}/Library/LaunchAgents}"
  local -a alerts files
  alerts=()
  _mac_ops_run_manifests
  files=("${reply[@]}")

  # Newest run, then the newest scheduled run
  local -A last sched
  local i
  for (( i = ${#files}; i >= 1; i-- )); do
    mac_ops_run_manifest_read "${files[i]}" || continue
    (( ${#last} )) || last=("${(@kv)MAC_OPS_MANIFEST}")
    if [[ "${MAC_OPS_MANIFEST[scheduled]}" == "true" ]]; then
      sched=("${(@kv)MAC_OPS_MANIFEST}")
      break
    fi
  done

  if (( ${#sched} )) && [[ "${sched[exit_status]:-1}" != "0" ]]; then
    alerts+=("last scheduled run ${sched[run_id]} FAILED (exit status ${sched[exit_status]:-?}, ${sched[errors]:-0} errors) - see: mac-ops runs, ${MAC_OPS_LOG_DIR}/mac-ops.log")
  fi

  # Scheduled agents: loaded? cleanup agent overdue?
  local label plist interval last_epoch now age age_h state
  local -a agent_lines
  agent_lines=()
  now=$(date +%s)
  for label in com.mac-ops.cleanup com.mac-ops.monitor; do
    plist="${agent_dir}/${label}.plist"
    if _mac_ops_agent_loaded "${label}"; then
      state="loaded"
    elif [[ -f "${plist}" ]]; then
      state="NOT LOADED (plist installed)"
      alerts+=("${label} is installed but not loaded by launchd - fix: launchctl load ${plist}")
    else
      state="not installed"
    fi
    agent_lines+=("${label}: ${state}")

    [[ "${label}" == "com.mac-ops.cleanup" && -f "${plist}" ]] || continue
    _mac_ops_agent_interval "${plist}"; interval="${REPLY}"
    [[ -n "${interval}" ]] || continue
    last_epoch=""
    if (( ${#sched} )); then
      _mac_ops_iso_to_epoch "${sched[ended]:-${sched[started]}}"; last_epoch="${REPLY}"
    fi
    if [[ -z "${last_epoch}" ]]; then
      # Never ran on schedule: measure from the installation of the plist
      last_epoch=$(stat -f %m "${plist}" 2>/dev/null) || last_epoch=""
    fi
    [[ "${last_epoch}" =~ ^[0-9]+$ ]] || continue
    age=$(( now - last_epoch ))
    if (( age > 3 * interval )); then
      _mac_ops_run_duration "${age}"; age_h="${REPLY}"
      _mac_ops_run_duration "${interval}"
      if (( ${#sched} )); then
        alerts+=("scheduled cleanup has not run for ${age_h} (interval ${REPLY}, more than three intervals)")
      else
        alerts+=("scheduled cleanup has never run since it was installed ${age_h} ago (interval ${REPLY})")
      fi
    fi
  done

  if (( ${#alerts} )); then
    print -r -- "[ALERT] ${(j: | :)alerts}"
  fi

  print "=== Health ==="
  if (( ${#last} )); then
    local kind="manual"
    [[ "${last[scheduled]}" == "true" ]] && kind="scheduled"
    local st="ok"
    [[ "${last[exit_status]:-1}" != "0" ]] && st="FAILED"
    print -r -- "Last run:         ${last[started]} UTC (${last[run_id]}, ${kind})"
    print -r -- "Exit status:      ${last[exit_status]:-?} (${st})"
    print -r -- "Errors/warnings:  ${last[errors]:-0} errors, ${last[warnings]:-0} warnings"
    print -r -- "Data items moved: ${last[data_items_moved]:-0} (settings/app data)"
    if (( ${#sched} )) && [[ "${sched[run_id]}" != "${last[run_id]}" ]]; then
      print -r -- "Last scheduled:   ${sched[started]} UTC (${sched[run_id]}, exit status ${sched[exit_status]:-?})"
    fi
  else
    print "Last run:         none recorded (${MAC_OPS_HOME}/runs)"
  fi
  for i in "${agent_lines[@]}"; do
    print -r -- "Agent ${i}"
  done
  return 0
}
