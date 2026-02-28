# =============================================================================
# mac-ops: Zombie process handling module
# Detect zombie processes with Z state and send signals to parent processes
# =============================================================================

# -----------------------------------------------------------------------------
# Zombie process handling main function
# 1. Detect zombie (Z) processes with ps aux
# 2. Check parent (PPID) and send SIGCHLD if not a protected process
# 3. Wait 3 seconds, if still zombie send SIGTERM to parent
# In DRY_RUN mode only output logs
# -----------------------------------------------------------------------------
mac_ops_zombie_killer() {
  local killed=0
  local zombie_list
  local zombie_count
  local ppid
  local parent_name
  local still_zombie

  mac_ops_log_info "Zombie process detection started"

  # Extract processes with Z state from ps aux
  # Exclude header (tail -n +2), filter rows with Z in state field (8th)
  zombie_list=$(ps aux | awk '$8 ~ /Z/ {print $2}' 2>/dev/null)

  if [[ -z "${zombie_list}" ]]; then
    mac_ops_log_info "No zombie processes found"
    return 0
  fi

  # Count zombies
  zombie_count=$(echo "${zombie_list}" | wc -l | tr -d ' ')
  mac_ops_log_info "${zombie_count} zombie processes found"

  while IFS= read -r zombie_pid; do
    [[ -z "${zombie_pid}" ]] && continue

    # Validate PID
    if [[ ! "${zombie_pid}" =~ ^[0-9]+$ ]]; then
      continue
    fi

    # Check zombie's parent PID
    ppid=$(ps -o ppid= -p "${zombie_pid}" 2>/dev/null | tr -d ' ')
    if [[ -z "${ppid}" || ! "${ppid}" =~ ^[0-9]+$ ]]; then
      mac_ops_log_debug "Zombie PID ${zombie_pid}: Cannot determine parent PID"
      continue
    fi

    # Check parent process name
    parent_name=$(ps -o comm= -p "${ppid}" 2>/dev/null | xargs basename 2>/dev/null)
    if [[ -z "${parent_name}" ]]; then
      mac_ops_log_debug "Zombie PID ${zombie_pid}: Cannot determine parent process name (PPID: ${ppid})"
      continue
    fi

    # Protected process check (return 0=unprotected, return 1=protected)
    if ! mac_ops_is_process_protected "${parent_name}" 2>/dev/null; then
      mac_ops_log_warn "Zombie PID ${zombie_pid}: Parent ${parent_name}(${ppid}) is a protected process, skipping"
      continue
    fi

    # User ignore rules: process name pattern
    if mac_ops_ignore_check_process "${parent_name}"; then
      mac_ops_log_debug "User ignore (process): ${parent_name} (PID: ${ppid})"
      continue
    fi

    mac_ops_log_info "Processing zombie PID ${zombie_pid} (parent: ${parent_name}, PPID: ${ppid})"

    # DRY_RUN mode
    if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
      mac_ops_log_info "[DRY_RUN] Will send SIGCHLD to parent PID ${ppid}(${parent_name})"
      killed=$((killed + 1))
      continue
    fi

    # Stage 1: Send SIGCHLD to parent (induce zombie reaping)
    mac_ops_log_info "Sending SIGCHLD to parent PID ${ppid}(${parent_name})"
    kill -SIGCHLD "${ppid}" 2>/dev/null

    # Wait 3 seconds
    sleep 3

    # Check if zombie still exists
    still_zombie=$(ps -o stat= -p "${zombie_pid}" 2>/dev/null | tr -d ' ')
    if [[ "${still_zombie}" == *Z* ]]; then
      # Stage 2: Send SIGTERM to parent
      mac_ops_log_warn "Zombie PID ${zombie_pid} still exists. Sending SIGTERM to parent PID ${ppid}(${parent_name})"
      kill -SIGTERM "${ppid}" 2>/dev/null
    else
      mac_ops_log_info "Zombie PID ${zombie_pid} successfully reaped (SIGCHLD)"
    fi

    killed=$((killed + 1))
  done <<< "${zombie_list}"

  # Accumulate global counter
  MAC_OPS_KILLED_COUNT=$((${MAC_OPS_KILLED_COUNT:-0} + killed))

  mac_ops_log_info "Zombie process handling completed: ${killed} processed"
  return 0
}
