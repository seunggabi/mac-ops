# =============================================================================
# mac-ops: Orphan process handling module
# Terminate old processes with PPID=1 not registered in launchctl
# =============================================================================

# --- Default settings ---
MAC_OPS_ORPHAN_MIN_RUNNING_HOURS=${MAC_OPS_ORPHAN_MIN_RUNNING_HOURS:-24}

# -----------------------------------------------------------------------------
# Orphan process handling main function
# 1. Detect processes with PPID=1
# 2. Filter processes not registered in launchctl
# 3. Target only those running for MinRunningHours or more
# 4. Check protected processes then SIGTERM -> wait 5 seconds -> SIGKILL
# In DRY_RUN mode only output logs
# -----------------------------------------------------------------------------
mac_ops_orphan_killer() {
  local min_hours="${MAC_OPS_ORPHAN_MIN_RUNNING_HOURS}"

  mac_ops_log_info "Orphan process detection started (threshold: running ${min_hours} hours or more)"

  local killed=0

  # Extract list of services registered in launchctl
  # Collect 3rd column (Label) from launchctl list
  local launchctl_services
  launchctl_services=$(launchctl list 2>/dev/null | awk 'NR>1 {print $3}')

  # List of processes with PPID=1 (pid, ppid, elapsed time, command)
  local orphan_list
  orphan_list=$(ps -eo pid=,ppid=,etime=,comm= 2>/dev/null | awk '$2 == 1 {print}')

  if [[ -z "${orphan_list}" ]]; then
    mac_ops_log_info "No orphan processes found"
    return 0
  fi

  # Declare variables inside loop (once only)
  local pid="" ppid="" etime="" comm="" proc_name=""
  local is_registered=false
  local running_hours=""

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue

    # Parse fields (separate with read at once, block stdout)
    pid=""; ppid=""; etime=""; comm=""; proc_name=""
    read -r pid ppid etime comm <<< "${line}"

    # Validate PID
    if [[ -z "${pid}" || ! "${pid}" =~ ^[0-9]+$ ]]; then
      continue
    fi

    # Extract process name (basename from path)
    proc_name="${comm##*/}"
    if [[ -z "${proc_name}" ]]; then
      continue
    fi

    # Skip processes without path (system daemons: autofsd, aslmanager, etc.)
    if [[ "${comm}" != /* ]]; then
      mac_ops_log_debug "System daemon skipped (no path): ${proc_name} (PID: ${pid})"
      continue
    fi

    # Filter system binary paths
    if [[ "${comm}" == /System/* || \
          "${comm}" == /usr/libexec/* || \
          "${comm}" == /usr/sbin/* || \
          "${comm}" == /usr/bin/* || \
          "${comm}" == /Library/Apple/* || \
          "${comm}" == /Library/PrivilegedHelperTools/* || \
          "${comm}" == /Library/Application\ Support/* || \
          "${comm}" == /Library/Developer/* || \
          "${comm}" == /sbin/* || \
          "${comm}" == /bin/* || \
          "${comm}" == /kernel* || \
          "${comm}" == /Applications/* ]]; then
      mac_ops_log_debug "System/service process skipped: ${proc_name} (${comm})"
      continue
    fi

    # Skip macOS app bundle processes (*.app/Contents/MacOS/*)
    if [[ "${comm}" == *".app/Contents/"* ]]; then
      mac_ops_log_debug "App bundle process skipped: ${proc_name} (${comm})"
      continue
    fi

    # Filter com.apple.* process names
    if [[ "${proc_name}" == com.apple.* ]]; then
      mac_ops_log_debug "Apple service skipped: ${proc_name} (PID: ${pid})"
      continue
    fi

    # Protected process check (return 0=unprotected, return 1=protected)
    if ! mac_ops_is_process_protected "${proc_name}" 2>/dev/null; then
      mac_ops_log_debug "Protected process skipped: ${proc_name} (PID: ${pid})"
      continue
    fi

    # Check if registered in launchctl
    # Skip if process name is included in service label
    is_registered=false
    if echo "${launchctl_services}" | grep -qi "${proc_name}" 2>/dev/null; then
      is_registered=true
    fi
    if [[ "${is_registered}" == "true" ]]; then
      mac_ops_log_debug "launchctl registered service skipped: ${proc_name} (PID: ${pid})"
      continue
    fi

    # Parse running time (etime format: [[DD-]HH:]MM:SS)
    running_hours=""
    running_hours=$(_mac_ops_parse_etime_hours "${etime}")
    if [[ -z "${running_hours}" ]]; then
      mac_ops_log_debug "Failed to parse running time: ${proc_name} (PID: ${pid}, etime: ${etime})"
      continue
    fi

    # Skip if less than MinRunningHours
    if [[ ${running_hours} -lt ${min_hours} ]]; then
      continue
    fi

    mac_ops_log_info "Orphan process found: ${proc_name} (PID: ${pid}, running: ${running_hours} hours)"

    # DRY_RUN mode
    if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
      mac_ops_log_info "[DRY_RUN] Will send SIGTERM to PID ${pid}(${proc_name})"
      killed=$((killed + 1))
      continue
    fi

    # Stage 1: Send SIGTERM
    mac_ops_log_info "Sending SIGTERM to PID ${pid}(${proc_name})"
    kill -SIGTERM "${pid}" 2>/dev/null

    # Wait 5 seconds
    sleep 5

    # Check if process still exists
    if kill -0 "${pid}" 2>/dev/null; then
      # Stage 2: Send SIGKILL
      mac_ops_log_warn "PID ${pid}(${proc_name}) still exists. Sending SIGKILL"
      kill -SIGKILL "${pid}" 2>/dev/null
    else
      mac_ops_log_info "PID ${pid}(${proc_name}) terminated normally (SIGTERM)"
    fi

    killed=$((killed + 1))
  done <<< "${orphan_list}"

  # Accumulate global counter
  MAC_OPS_KILLED_COUNT=$((${MAC_OPS_KILLED_COUNT:-0} + killed))

  mac_ops_log_info "Orphan process handling completed: ${killed} processed"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Convert etime string to hours integer
# etime format: [[DD-]HH:]MM:SS
# Examples: "02:30" -> 0, "01:02:30" -> 1, "3-01:02:30" -> 73
# Usage: _mac_ops_parse_etime_hours <etime>
# -----------------------------------------------------------------------------
_mac_ops_parse_etime_hours() {
  local etime="${1}"
  local days=0
  local hours=0
  local minutes=0

  # DD-HH:MM:SS format (includes days)
  if [[ "${etime}" == *-* ]]; then
    days=${etime%%-*}
    etime=${etime#*-}
  fi

  # Parse according to colon count
  local colon_count
  colon_count=$(echo "${etime}" | tr -cd ':' | wc -c | tr -d ' ')

  if [[ ${colon_count} -eq 2 ]]; then
    # HH:MM:SS
    hours=$(echo "${etime}" | cut -d: -f1)
    minutes=$(echo "${etime}" | cut -d: -f2)
  elif [[ ${colon_count} -eq 1 ]]; then
    # MM:SS
    minutes=$(echo "${etime}" | cut -d: -f1)
  fi

  # Remove leading zeros (08 -> 8, etc., prevent arithmetic errors)
  days=$((10#${days}))
  hours=$((10#${hours}))
  minutes=$((10#${minutes}))

  local total_hours=$((days * 24 + hours))
  print -- "${total_hours}"
}
