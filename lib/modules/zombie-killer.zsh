# =============================================================================
# mac-ops: Zombie process module
# Report zombie (Z state) processes; optionally nudge their parents with SIGCHLD
# =============================================================================
#
# A zombie holds no memory, files or CPU: only a process-table slot. It is never
# worth ending a live parent for, so this module never sends SIGTERM or SIGKILL
# to anything. What it does:
#   report (default) - log each zombie: PID, parent PID, parent executable,
#                      and the time since the process started (ps etime)
#   sigchld          - also send SIGCHLD (a "reap your children" hint, harmless
#                      to a correct program) to each eligible parent
# Only the exact value "sigchld" signals. Every other value behaves like "report".
# A parent is never signalled when it is PID 1, an ancestor of this mac-ops run,
# a protected or user-ignored process, or its executable path contains a
# security software keyword (MAC_OPS_SECURITY_KEYWORDS, lib/utils/security-keywords.zsh).

# zsh-only parameter flags and nested expansions; false positives in bash mode
# shellcheck disable=SC2296,SC2299

MAC_OPS_ZOMBIE_ACTION=${MAC_OPS_ZOMBIE_ACTION:-report}

# -----------------------------------------------------------------------------
# Zombie process main function
# -----------------------------------------------------------------------------
mac_ops_zombie_killer() {
  local ps_out="" line="" pid="" ppid="" stat="" etime="" comm=""
  local parent_exec="" parent_name="" reason="" cur="" hops=0 found=0 signalled=0
  local -A parent_of=() exec_of=() ancestors=()
  local -a zombies=()

  mac_ops_log_info "Zombie process detection started"

  # One snapshot of the process table: pid, ppid, state, elapsed time, executable
  ps_out=$(ps -axo pid=,ppid=,stat=,etime=,comm= 2>/dev/null)
  if [[ $? -ne 0 || -z "${ps_out}" ]]; then
    mac_ops_log_warn "Zombie detection: process list unavailable (ps failed). Skipping."
    return 0
  fi

  while IFS= read -r line; do
    read -r pid ppid stat etime comm <<< "${line}"
    [[ "${pid}" =~ ^[0-9]+$ && "${ppid}" =~ ^[0-9]+$ ]] || continue
    parent_of[${pid}]="${ppid}"
    exec_of[${pid}]="${comm}"
    [[ "${stat}" == *Z* ]] && zombies+=("${pid}|${ppid}|${etime}")
  done <<< "${ps_out}"

  if [[ ${#zombies[@]} -eq 0 ]]; then
    mac_ops_log_info "No zombie processes found"
    return 0
  fi
  mac_ops_log_info "${#zombies[@]} zombie processes found"

  # This run and every process above it are never signalled
  cur="$$"
  while [[ -n "${cur}" && ${hops} -lt 64 ]]; do
    ancestors[${cur}]=1
    [[ "${cur}" == "1" || "${cur}" == "0" ]] && break
    cur="${parent_of[${cur}]:-}"
    hops=$((hops + 1))
  done

  for line in "${zombies[@]}"; do
    pid="${line%%|*}"
    ppid="${${line#*|}%%|*}"
    etime="${line##*|}"
    parent_exec="${exec_of[${ppid}]:-unknown}"
    parent_name="${parent_exec:t}"
    found=$((found + 1))

    mac_ops_log_info "Zombie PID ${pid}: parent PID ${ppid} (${parent_exec}), process started ${etime} ago"

    reason=$(_mac_ops_zombie_parent_unsafe "${ppid}" "${parent_exec}" "${parent_name}" "${(j: :)${(k)ancestors}}")
    if [[ -n "${reason}" ]]; then
      mac_ops_log_info "Zombie PID ${pid}: parent ${parent_name}(${ppid}) is never signalled (${reason})"
      continue
    fi

    if [[ "${MAC_OPS_ZOMBIE_ACTION}" != "sigchld" ]]; then
      continue
    fi

    if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
      mac_ops_log_info "[DRY_RUN] Would send SIGCHLD to parent PID ${ppid}(${parent_name})"
      continue
    fi

    # Re-check right before signalling: the zombie must still be a zombie of
    # the same parent, and the parent must still run the same executable
    if [[ "$(ps -o stat= -p "${pid}" 2>/dev/null | tr -d ' ')" != *Z* \
       || "$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ')" != "${ppid}" \
       || "$(ps -o comm= -p "${ppid}" 2>/dev/null)" != "${parent_exec}" ]]; then
      mac_ops_log_info "Zombie PID ${pid}: changed since detection, not signalling its parent"
      continue
    fi

    mac_ops_log_info "Sending SIGCHLD to parent PID ${ppid}(${parent_name})"
    kill -CHLD "${ppid}" 2>/dev/null && signalled=$((signalled + 1))
  done

  if [[ "${MAC_OPS_ZOMBIE_ACTION}" != "sigchld" ]]; then
    mac_ops_log_info "Zombie processes: ${found} reported, none signalled (set MAC_OPS_ZOMBIE_ACTION=sigchld to send SIGCHLD to eligible parents)"
  else
    mac_ops_log_info "Zombie processes: ${found} reported, ${signalled} parents sent SIGCHLD"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Print why a zombie's parent must not be signalled (empty = eligible)
# Usage: _mac_ops_zombie_parent_unsafe <ppid> <parent exec> <parent name> <ancestor pids>
# -----------------------------------------------------------------------------
_mac_ops_zombie_parent_unsafe() {
  local ppid="${1}" parent_exec="${2}" parent_name="${3}"
  local -a ancestor_pids=(${=4})

  if [[ ! "${ppid}" =~ ^[0-9]+$ ]] || (( ppid <= 1 )); then
    print -- "PID 1 (launchd) or invalid parent"
  elif (( ${ancestor_pids[(Ie)${ppid}]} )); then
    print -- "ancestor of this mac-ops run"
  elif [[ "${parent_exec}" == "unknown" || -z "${parent_name}" ]]; then
    print -- "parent executable unknown"
  elif ! (( ${+functions[_mac_ops_fc_is_security_path]} )); then
    print -- "security software check unavailable"
  elif _mac_ops_fc_is_security_path "${parent_exec}"; then
    print -- "security software"
  elif (( ${+functions[mac_ops_is_process_protected]} )) && ! mac_ops_is_process_protected "${parent_name}" 2>/dev/null; then
    print -- "protected process"
  elif (( ${+functions[mac_ops_ignore_check_process]} )) && mac_ops_ignore_check_process "${parent_name}"; then
    print -- "user ignore rule"
  fi
  return 0
}
