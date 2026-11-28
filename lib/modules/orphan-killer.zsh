# =============================================================================
# mac-ops: Orphan process handling module
# Report (default) or SIGTERM (opt-in) stray processes with PPID=1.
#
# A parent of PID 1 plus a long uptime is NOT enough to call a process an
# orphan: tmux servers, ssh-agent, launchd agents, app helpers and daemonized
# tools all look like that by design. A process is a candidate only if ALL of
# the following hold:
#   - it is not in this tool's own process tree (self, ancestors, descendants)
#   - its executable is not security software
#   - its parent is PID 1
#   - it is owned by the current user
#   - it is not managed by launchd (PID not listed in `launchctl list`)
#   - it has no controlling tty
#   - its executable is not inside a .app bundle
#   - neither it nor any ancestor/descendant is a terminal, shell, tmux or
#     coding-agent session, and no descendant has a controlling tty
#   - it has no child process (something may depend on it)
#   - its executable is not a user daemon started on purpose (gpg-agent,
#     ollama, limactl, databases, web servers, a pm2 God daemon, ...)
#   - it passes the path / protected-process / user-ignore filters
#   - it has been running for MAC_OPS_ORPHAN_MIN_RUNNING_HOURS or more
#     (a whole number >= 1; anything else falls back to 24)
#
# All name-based rules compare the executable (`ps -o comm=`), never the
# argument list. The one exception only protects: a node process whose title
# starts with "PM2" (pm2 God daemon) is never a candidate.
# =============================================================================

# --- Default settings ---
MAC_OPS_ORPHAN_MIN_RUNNING_HOURS=${MAC_OPS_ORPHAN_MIN_RUNNING_HOURS:-24}
# report (default): only list candidates. term: send SIGTERM to candidates.
# SIGKILL is never sent by this module.
MAC_OPS_ORPHAN_ACTION=${MAC_OPS_ORPHAN_ACTION:-report}

# Security software (MAC_OPS_SECURITY_KEYWORDS, lib/utils/security-keywords.zsh)
# is never signalled: case-insensitive substring of the executable path.

# --- User daemons: long-running tools started on purpose, never signalled ---
# Exact, case-insensitive match on the executable base name. Name families
# (qemu-system-*, jupyter*) are matched by prefix in _mac_ops_orphan_is_user_daemon.
_MAC_OPS_ORPHAN_USER_DAEMONS=(
  gpg-agent dirmngr scdaemon ssh-agent
  ollama limactl colima podman dockerd containerd buildkitd
  pm2 emacs tmux screen mosh-server
  syncthing rclone cloudflared ngrok tailscaled
  postgres postmaster mysqld mariadbd redis-server mongod memcached
  nginx httpd caddy jupyter code-server
)

# --- Process table snapshot (filled by _mac_ops_orphan_load_snapshot) ---
typeset -ga _MAC_OPS_ORPHAN_PIDS
typeset -gA _MAC_OPS_ORPHAN_PPID
typeset -gA _MAC_OPS_ORPHAN_UID
typeset -gA _MAC_OPS_ORPHAN_TTY
typeset -gA _MAC_OPS_ORPHAN_ETIME
typeset -gA _MAC_OPS_ORPHAN_RSS
typeset -gA _MAC_OPS_ORPHAN_EXE
typeset -gA _MAC_OPS_ORPHAN_KIDS
typeset -gA _MAC_OPS_ORPHAN_OWN_TREE
typeset -gA _MAC_OPS_ORPHAN_LAUNCHD_PIDS
typeset -g _MAC_OPS_ORPHAN_LAUNCHD_LABELS=""
# Result slots of the predicate helpers
typeset -g _MAC_OPS_ORPHAN_REASON=""
typeset -g _MAC_OPS_ORPHAN_CHECKS=""

# -----------------------------------------------------------------------------
# Main function
# 1. Snapshot the process table and the launchd-managed PIDs
# 2. Classify every process whose parent is PID 1 and log the decision
# 3. Report candidates (PID, uptime, memory, executable, why)
# 4. Only with MAC_OPS_ORPHAN_ACTION=term and outside DRY_RUN: re-verify each
#    candidate (same start time, same executable) and send SIGTERM
# -----------------------------------------------------------------------------
mac_ops_orphan_killer() {
  local min_hours=""
  if ! min_hours=$(_mac_ops_orphan_min_hours); then
    mac_ops_log_warn "MAC_OPS_ORPHAN_MIN_RUNNING_HOURS='${MAC_OPS_ORPHAN_MIN_RUNNING_HOURS}' is not a whole number of hours >= 1; using 24"
  fi

  mac_ops_log_info "Orphan process detection started (threshold: running ${min_hours} hours or more)"

  local action=""
  action=$(_mac_ops_orphan_action)
  if [[ "${action}" == "term" ]]; then
    mac_ops_log_info "Orphan process action: term (SIGTERM only, never SIGKILL)"
  else
    mac_ops_log_info "Orphan process action: report (no signal is sent; set MAC_OPS_ORPHAN_ACTION=term to send SIGTERM)"
  fi

  if ! _mac_ops_orphan_load_snapshot; then
    mac_ops_log_warn "Orphan process detection skipped: could not read the process table"
    return 0
  fi
  _mac_ops_orphan_load_launchd

  local -a candidates
  candidates=()
  local pid="" exe="" lstart="" exe_now=""
  local examined=0

  for pid in "${_MAC_OPS_ORPHAN_PIDS[@]}"; do
    [[ "${_MAC_OPS_ORPHAN_PPID[${pid}]}" == "1" ]] || continue
    examined=$((examined + 1))
    exe="${_MAC_OPS_ORPHAN_EXE[${pid}]}"

    if ! _mac_ops_orphan_classify "${pid}"; then
      mac_ops_log_debug "Orphan process candidate rejected: PID ${pid} (${exe}): ${_MAC_OPS_ORPHAN_REASON}"
      continue
    fi

    # Record the identity used for the re-check right before any signal
    lstart=$(_mac_ops_orphan_lstart "${pid}")
    exe_now=$(_mac_ops_orphan_exe "${pid}")
    if [[ -z "${lstart}" || "${exe_now}" != "${exe}" ]]; then
      mac_ops_log_debug "Orphan process candidate rejected: PID ${pid} (${exe}): gone or replaced while listing"
      continue
    fi

    mac_ops_log_info "Orphan process candidate: PID ${pid} | uptime $(_mac_ops_orphan_format_uptime "${_MAC_OPS_ORPHAN_ETIME[${pid}]}") | memory $(_mac_ops_orphan_format_rss "${_MAC_OPS_ORPHAN_RSS[${pid}]}") | executable ${exe} | why: ${_MAC_OPS_ORPHAN_CHECKS}"
    candidates+=("${pid}"$'\t'"${lstart}"$'\t'"${exe}")
  done

  local found=${#candidates[@]}
  local signalled=0

  if [[ "${action}" != "term" ]]; then
    mac_ops_log_info "Orphan process handling completed: ${found} candidates reported out of ${examined} parent-1 processes, 0 signalled (report only)"
    return 0
  fi

  local entry="" rc=0
  for entry in "${candidates[@]}"; do
    pid=""; lstart=""; exe=""
    IFS=$'\t' read -r pid lstart exe <<< "${entry}"
    _mac_ops_orphan_terminate "${pid}" "${lstart}" "${exe}"
    rc=$?
    # 0 = SIGTERM sent, 3 = DRY_RUN (would send)
    if [[ ${rc} -eq 0 || ${rc} -eq 3 ]]; then
      signalled=$((signalled + 1))
    fi
  done

  # Accumulate global counter
  MAC_OPS_KILLED_COUNT=$((${MAC_OPS_KILLED_COUNT:-0} + signalled))

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "Orphan process handling completed: ${found} candidates out of ${examined} parent-1 processes, ${signalled} would be sent SIGTERM (dry-run, no signal sent)"
  else
    mac_ops_log_info "Orphan process handling completed: ${found} candidates out of ${examined} parent-1 processes, ${signalled} sent SIGTERM"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Resolve the configured action
# Prints "term" only for the exact value "term"; everything else is "report".
# Usage: _mac_ops_orphan_action
# -----------------------------------------------------------------------------
_mac_ops_orphan_action() {
  if [[ "${MAC_OPS_ORPHAN_ACTION:-report}" == "term" ]]; then
    print -- "term"
  else
    print -- "report"
  fi
}

# -----------------------------------------------------------------------------
# Internal: Resolve the uptime threshold in hours
# Accepts only a whole number >= 1 (at most 6 digits). Unset/empty means the
# default 24. Anything else (abc, 0, -5, 24h, 1.5) prints 24 and returns 1 so
# the caller can warn; the uptime filter is never turned off.
# Usage: _mac_ops_orphan_min_hours
# -----------------------------------------------------------------------------
_mac_ops_orphan_min_hours() {
  local value="${MAC_OPS_ORPHAN_MIN_RUNNING_HOURS-}"
  if [[ -z "${value}" ]]; then
    print -- "24"
    return 0
  fi
  if [[ "${value}" =~ ^[0-9]+$ && ${#value} -le 6 ]] && (( 10#${value} >= 1 )); then
    print -- "$((10#${value}))"
    return 0
  fi
  print -- "24"
  return 1
}

# -----------------------------------------------------------------------------
# Internal: Load a process table snapshot into the lookup tables
# Row format (one process per line): pid ppid uid tty etime rss comm
# With no argument the live table is read (read-only `ps`).
# Usage: _mac_ops_orphan_load_snapshot [table_text] [self_pid]
# -----------------------------------------------------------------------------
_mac_ops_orphan_load_snapshot() {
  local table="${1:-}"
  local self_pid="${2:-$$}"

  if [[ -z "${table}" ]]; then
    table=$(ps -axo pid=,ppid=,uid=,tty=,etime=,rss=,comm= 2>/dev/null)
  fi

  _MAC_OPS_ORPHAN_PIDS=()
  _MAC_OPS_ORPHAN_PPID=()
  _MAC_OPS_ORPHAN_UID=()
  _MAC_OPS_ORPHAN_TTY=()
  _MAC_OPS_ORPHAN_ETIME=()
  _MAC_OPS_ORPHAN_RSS=()
  _MAC_OPS_ORPHAN_EXE=()
  _MAC_OPS_ORPHAN_KIDS=()
  _MAC_OPS_ORPHAN_OWN_TREE=()

  [[ -z "${table}" ]] && return 1

  local pid="" ppid="" uid="" tty="" etime="" rss="" comm=""
  while read -r pid ppid uid tty etime rss comm; do
    [[ "${pid}" =~ ^[0-9]+$ && "${ppid}" =~ ^[0-9]+$ ]] || continue
    _MAC_OPS_ORPHAN_PIDS+=("${pid}")
    _MAC_OPS_ORPHAN_PPID[${pid}]="${ppid}"
    _MAC_OPS_ORPHAN_UID[${pid}]="${uid}"
    _MAC_OPS_ORPHAN_TTY[${pid}]="${tty}"
    _MAC_OPS_ORPHAN_ETIME[${pid}]="${etime}"
    _MAC_OPS_ORPHAN_RSS[${pid}]="${rss}"
    _MAC_OPS_ORPHAN_EXE[${pid}]="${comm}"
    # Children list: newline-terminated PIDs
    _MAC_OPS_ORPHAN_KIDS[${ppid}]+="${pid}"$'\n'
  done <<< "${table}"

  [[ ${#_MAC_OPS_ORPHAN_PIDS[@]} -eq 0 ]] && return 1

  # Mark this tool's own process tree: self, ancestors, descendants
  local own=""
  _MAC_OPS_ORPHAN_OWN_TREE[${self_pid}]=1
  while IFS= read -r own; do
    [[ -n "${own}" ]] && _MAC_OPS_ORPHAN_OWN_TREE[${own}]=1
  done <<< "$(_mac_ops_orphan_ancestors "${self_pid}"; _mac_ops_orphan_descendants "${self_pid}")"

  return 0
}

# -----------------------------------------------------------------------------
# Internal: Load launchd-managed PIDs and labels
# Input format is `launchctl list` output (PID, Status, Label).
# With no argument the live list is read.
# Usage: _mac_ops_orphan_load_launchd [list_text]
# -----------------------------------------------------------------------------
_mac_ops_orphan_load_launchd() {
  local list="${1:-}"
  if [[ -z "${list}" ]]; then
    list=$(launchctl list 2>/dev/null)
  fi

  _MAC_OPS_ORPHAN_LAUNCHD_PIDS=()
  _MAC_OPS_ORPHAN_LAUNCHD_LABELS=""

  local lpid="" lstatus="" label=""
  while read -r lpid lstatus label; do
    [[ -n "${label}" ]] && _MAC_OPS_ORPHAN_LAUNCHD_LABELS+="${label}"$'\n'
    [[ "${lpid}" =~ ^[0-9]+$ ]] && _MAC_OPS_ORPHAN_LAUNCHD_PIDS[${lpid}]=1
  done <<< "${list}"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Print the ancestors of a PID (nearest first, PID 0/1 excluded)
# Usage: _mac_ops_orphan_ancestors <pid>
# -----------------------------------------------------------------------------
_mac_ops_orphan_ancestors() {
  local cur="${_MAC_OPS_ORPHAN_PPID[${1}]}"
  local depth=0
  while [[ -n "${cur}" && "${cur}" != "0" && "${cur}" != "1" && ${depth} -lt 64 ]]; do
    print -- "${cur}"
    cur="${_MAC_OPS_ORPHAN_PPID[${cur}]}"
    depth=$((depth + 1))
  done
}

# -----------------------------------------------------------------------------
# Internal: Print all descendants of a PID (breadth first)
# Usage: _mac_ops_orphan_descendants <pid>
# -----------------------------------------------------------------------------
_mac_ops_orphan_descendants() {
  local queue="${_MAC_OPS_ORPHAN_KIDS[${1}]}"
  local next="" kid=""
  local depth=0
  while [[ -n "${queue}" && ${depth} -lt 64 ]]; do
    next=""
    while IFS= read -r kid; do
      [[ -z "${kid}" ]] && continue
      print -- "${kid}"
      next+="${_MAC_OPS_ORPHAN_KIDS[${kid}]}"
    done <<< "${queue}"
    queue="${next}"
    depth=$((depth + 1))
  done
}

# -----------------------------------------------------------------------------
# Internal: Is the PID part of this tool's own process tree?
# (the shell that loaded the snapshot, its ancestors and its descendants)
# Return 0 if yes
# Usage: _mac_ops_orphan_in_own_tree <pid>
# -----------------------------------------------------------------------------
_mac_ops_orphan_in_own_tree() {
  [[ -n "${_MAC_OPS_ORPHAN_OWN_TREE[${1}]}" ]]
}

# -----------------------------------------------------------------------------
# Internal: Is the executable a terminal, shell, multiplexer or coding agent?
# Exact, case-insensitive match on the executable basename (a leading "-" of
# login shells is ignored). Arguments are never looked at.
# Return 0 if yes
# Usage: _mac_ops_orphan_is_session_exe <executable_path>
# -----------------------------------------------------------------------------
_mac_ops_orphan_is_session_exe() {
  typeset -l base="${1##*/}"
  base="${base#-}"
  case "${base}" in
    sh|bash|zsh|fish|dash|ksh|tcsh|csh|nu|pwsh|login) return 0 ;;
    tmux|screen|zellij|mosh-server|sshd|ssh|ssh-agent) return 0 ;;
    terminal|iterm2|iterm|alacritty|kitty|wezterm|wezterm-gui|ghostty|warp|hyper|tabby) return 0 ;;
    claude|codex|cursor|cursor-agent|gemini|aider|opencode|amp|goose|copilot|windsurf|code) return 0 ;;
  esac
  return 1
}

# -----------------------------------------------------------------------------
# Internal: Process title of a live PID (`ps -o args=`, empty if gone)
# Only used to protect a pm2 God daemon, never to make a process a candidate.
# Usage: _mac_ops_orphan_title <pid>
# -----------------------------------------------------------------------------
_mac_ops_orphan_title() {
  ps -o args= -p "${1}" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# -----------------------------------------------------------------------------
# Internal: Is the executable a user daemon started on purpose?
# Exact, case-insensitive match of the executable base name against
# _MAC_OPS_ORPHAN_USER_DAEMONS. A process whose executable or title starts
# with "PM2" is a pm2 God daemon (pm2 runs it as node with that title).
# Return 0 if yes; _MAC_OPS_ORPHAN_REASON says which rule matched.
# Usage: _mac_ops_orphan_is_user_daemon <executable_path> [process_title]
# -----------------------------------------------------------------------------
_mac_ops_orphan_is_user_daemon() {
  local exe="${1}" title="${2:-}"
  typeset -l base="${exe##*/}"
  local name=""

  if [[ "${exe}" == [Pp][Mm]2* || "${title}" == [Pp][Mm]2* ]]; then
    _MAC_OPS_ORPHAN_REASON="user daemon: pm2 God daemon (process title starts with PM2)"
    return 0
  fi

  if [[ "${base}" == qemu-system-* || "${base}" == jupyter* ]]; then
    _MAC_OPS_ORPHAN_REASON="user daemon started on purpose (${base})"
    return 0
  fi
  for name in "${_MAC_OPS_ORPHAN_USER_DAEMONS[@]}"; do
    if [[ "${base}" == "${name}" ]]; then
      _MAC_OPS_ORPHAN_REASON="user daemon started on purpose (${base})"
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# Internal: Is the PID, an ancestor or a descendant a live session?
# Session = terminal / shell / tmux / coding agent executable, or (for the
# PID's descendants) a process with a controlling tty.
# Return 0 if linked; _MAC_OPS_ORPHAN_REASON names the relative.
# Usage: _mac_ops_orphan_session_link <pid>
# -----------------------------------------------------------------------------
_mac_ops_orphan_session_link() {
  local pid="${1}"
  local rel=""

  if _mac_ops_orphan_is_session_exe "${_MAC_OPS_ORPHAN_EXE[${pid}]}"; then
    _MAC_OPS_ORPHAN_REASON="executable is a terminal/shell/tmux/coding-agent session"
    return 0
  fi

  while IFS= read -r rel; do
    [[ -z "${rel}" ]] && continue
    if _mac_ops_orphan_is_session_exe "${_MAC_OPS_ORPHAN_EXE[${rel}]}"; then
      _MAC_OPS_ORPHAN_REASON="ancestor PID ${rel} (${_MAC_OPS_ORPHAN_EXE[${rel}]}) is a session"
      return 0
    fi
  done <<< "$(_mac_ops_orphan_ancestors "${pid}")"

  while IFS= read -r rel; do
    [[ -z "${rel}" ]] && continue
    if _mac_ops_orphan_is_session_exe "${_MAC_OPS_ORPHAN_EXE[${rel}]}"; then
      _MAC_OPS_ORPHAN_REASON="descendant PID ${rel} (${_MAC_OPS_ORPHAN_EXE[${rel}]}) is a session"
      return 0
    fi
    if _mac_ops_orphan_has_tty "${_MAC_OPS_ORPHAN_TTY[${rel}]}"; then
      _MAC_OPS_ORPHAN_REASON="descendant PID ${rel} has controlling tty ${_MAC_OPS_ORPHAN_TTY[${rel}]}"
      return 0
    fi
  done <<< "$(_mac_ops_orphan_descendants "${pid}")"

  return 1
}

# -----------------------------------------------------------------------------
# Internal: Does a `ps -o tty=` value name a controlling terminal?
# Return 0 if yes ("??", "-" and empty mean no tty)
# Usage: _mac_ops_orphan_has_tty <tty_field>
# -----------------------------------------------------------------------------
_mac_ops_orphan_has_tty() {
  case "${1}" in
    ""|"?"|"??"|"-") return 1 ;;
  esac
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Is the executable inside a .app bundle?
# Return 0 if yes
# Usage: _mac_ops_orphan_in_app_bundle <executable_path>
# -----------------------------------------------------------------------------
_mac_ops_orphan_in_app_bundle() {
  [[ "${1}" == *.app/* ]]
}

# -----------------------------------------------------------------------------
# Internal: Path / name filters judged on the executable only
# (system paths, Apple services, protected processes, user ignore rules,
# launchd label match). Return 0 if the executable must be skipped;
# _MAC_OPS_ORPHAN_REASON says why.
# Usage: _mac_ops_orphan_exe_filtered <executable_path>
# -----------------------------------------------------------------------------
_mac_ops_orphan_exe_filtered() {
  local exe="${1}"
  local proc_name="${exe##*/}"

  if [[ -z "${proc_name}" ]]; then
    _MAC_OPS_ORPHAN_REASON="empty executable name"
    return 0
  fi

  # Processes without a path (system daemons: autofsd, aslmanager, etc.)
  if [[ "${exe}" != /* ]]; then
    _MAC_OPS_ORPHAN_REASON="executable has no path (system daemon)"
    return 0
  fi

  # System binary paths
  if [[ "${exe}" == /System/* || \
        "${exe}" == /usr/libexec/* || \
        "${exe}" == /usr/sbin/* || \
        "${exe}" == /usr/bin/* || \
        "${exe}" == /Library/Apple/* || \
        "${exe}" == /Library/PrivilegedHelperTools/* || \
        "${exe}" == /Library/Application\ Support/* || \
        "${exe}" == /Library/Developer/* || \
        "${exe}" == /sbin/* || \
        "${exe}" == /bin/* || \
        "${exe}" == /kernel* || \
        "${exe}" == /Applications/* ]]; then
    _MAC_OPS_ORPHAN_REASON="system/service executable path"
    return 0
  fi

  if [[ "${proc_name}" == com.apple.* ]]; then
    _MAC_OPS_ORPHAN_REASON="Apple service"
    return 0
  fi

  # Protected process check (return 0=unprotected, return 1=protected)
  if ! mac_ops_is_process_protected "${proc_name}" >/dev/null 2>&1; then
    _MAC_OPS_ORPHAN_REASON="protected process"
    return 0
  fi

  # User ignore rules: executable name or full executable path
  if typeset -f mac_ops_ignore_check_process >/dev/null 2>&1; then
    if mac_ops_ignore_check_process "${proc_name}" || mac_ops_ignore_check_process "${exe}"; then
      _MAC_OPS_ORPHAN_REASON="user ignore rule"
      return 0
    fi
  fi

  # launchd service label containing the executable name
  if [[ -n "${_MAC_OPS_ORPHAN_LAUNCHD_LABELS}" ]] && \
     print -r -- "${_MAC_OPS_ORPHAN_LAUNCHD_LABELS}" | grep -qiF -- "${proc_name}" 2>/dev/null; then
    _MAC_OPS_ORPHAN_REASON="launchd service label matches executable name"
    return 0
  fi

  return 1
}

# -----------------------------------------------------------------------------
# Internal: Decide whether a PID of the loaded snapshot is an orphan candidate
# Return 0 = candidate (_MAC_OPS_ORPHAN_CHECKS lists the checks it passed)
# Return 1 = not a candidate (_MAC_OPS_ORPHAN_REASON says which check failed)
# Usage: _mac_ops_orphan_classify <pid>
# -----------------------------------------------------------------------------
_mac_ops_orphan_classify() {
  local pid="${1}"
  local exe="${_MAC_OPS_ORPHAN_EXE[${pid}]}"
  local min_hours=""
  min_hours=$(_mac_ops_orphan_min_hours)

  _MAC_OPS_ORPHAN_REASON=""
  _MAC_OPS_ORPHAN_CHECKS=""

  if [[ -z "${_MAC_OPS_ORPHAN_PPID[${pid}]}" ]]; then
    _MAC_OPS_ORPHAN_REASON="not in the process table snapshot"
    return 1
  fi

  if _mac_ops_orphan_in_own_tree "${pid}"; then
    _MAC_OPS_ORPHAN_REASON="part of mac-ops' own process tree"
    return 1
  fi

  # Fail closed: without the security keyword check (security-keywords.zsh
  # not loaded) no process is a candidate
  if ! (( ${+functions[_mac_ops_fc_is_security_path]} )); then
    _MAC_OPS_ORPHAN_REASON="security software check unavailable"
    return 1
  fi
  if _mac_ops_fc_is_security_path "${exe}"; then
    _MAC_OPS_ORPHAN_REASON="security software"
    return 1
  fi

  if [[ "${_MAC_OPS_ORPHAN_PPID[${pid}]}" != "1" ]]; then
    _MAC_OPS_ORPHAN_REASON="parent is PID ${_MAC_OPS_ORPHAN_PPID[${pid}]}, not PID 1"
    return 1
  fi

  # launchd jobs of other users/domains are not visible to `launchctl list`
  if [[ "${_MAC_OPS_ORPHAN_UID[${pid}]}" != "${UID}" ]]; then
    _MAC_OPS_ORPHAN_REASON="owned by another user (uid ${_MAC_OPS_ORPHAN_UID[${pid}]})"
    return 1
  fi

  if [[ -n "${_MAC_OPS_ORPHAN_LAUNCHD_PIDS[${pid}]}" ]]; then
    _MAC_OPS_ORPHAN_REASON="managed by launchd (PID listed in launchctl list)"
    return 1
  fi

  if _mac_ops_orphan_has_tty "${_MAC_OPS_ORPHAN_TTY[${pid}]}"; then
    _MAC_OPS_ORPHAN_REASON="has controlling tty ${_MAC_OPS_ORPHAN_TTY[${pid}]}"
    return 1
  fi

  if _mac_ops_orphan_in_app_bundle "${exe}"; then
    _MAC_OPS_ORPHAN_REASON="executable is inside a .app bundle"
    return 1
  fi

  # Sets _MAC_OPS_ORPHAN_REASON on match
  if _mac_ops_orphan_session_link "${pid}"; then
    return 1
  fi

  # Something still depends on a process that has children
  local first_kid="${_MAC_OPS_ORPHAN_KIDS[${pid}]}"
  first_kid="${first_kid%%$'\n'*}"
  if [[ -n "${first_kid}" ]]; then
    _MAC_OPS_ORPHAN_REASON="has child process PID ${first_kid}"
    return 1
  fi

  # Sets _MAC_OPS_ORPHAN_REASON on match. The title is read only for node,
  # because a pm2 God daemon runs as node with a "PM2 ..." title.
  local title=""
  typeset -l lower_base="${exe##*/}"
  if [[ "${lower_base}" == node || "${lower_base}" == node[0-9]* ]]; then
    title=$(_mac_ops_orphan_title "${pid}")
  fi
  if _mac_ops_orphan_is_user_daemon "${exe}" "${title}"; then
    return 1
  fi

  # Sets _MAC_OPS_ORPHAN_REASON on match
  if _mac_ops_orphan_exe_filtered "${exe}"; then
    return 1
  fi

  local running_hours=""
  running_hours=$(_mac_ops_parse_etime_hours "${_MAC_OPS_ORPHAN_ETIME[${pid}]}" 2>/dev/null)
  if [[ ! "${running_hours}" =~ ^[0-9]+$ ]]; then
    _MAC_OPS_ORPHAN_REASON="could not parse uptime (${_MAC_OPS_ORPHAN_ETIME[${pid}]})"
    return 1
  fi
  if [[ ${running_hours} -lt ${min_hours} ]]; then
    _MAC_OPS_ORPHAN_REASON="running ${running_hours}h, below the ${min_hours}h threshold"
    return 1
  fi

  _MAC_OPS_ORPHAN_CHECKS="not in own process tree; not security software; parent is PID 1; owned by current user; not launchd-managed; no controlling tty; not inside a .app bundle; no terminal/shell/tmux/agent relative; no child process; not a user daemon; not system/protected/ignored; running ${running_hours}h >= ${min_hours}h"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Current start time / executable of a live PID (empty if gone)
# Usage: _mac_ops_orphan_lstart <pid> ; _mac_ops_orphan_exe <pid>
# -----------------------------------------------------------------------------
_mac_ops_orphan_lstart() {
  ps -o lstart= -p "${1}" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

_mac_ops_orphan_exe() {
  ps -o comm= -p "${1}" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# -----------------------------------------------------------------------------
# Internal: Is the PID still the process that was listed?
# It must exist with the same start time and the same executable.
# Return 0 if identical
# Usage: _mac_ops_orphan_verify <pid> <recorded_lstart> <recorded_executable>
# -----------------------------------------------------------------------------
_mac_ops_orphan_verify() {
  local pid="${1}" recorded_lstart="${2}" recorded_exe="${3}"
  local now_lstart="" now_exe=""

  [[ "${pid}" =~ ^[0-9]+$ && -n "${recorded_lstart}" && -n "${recorded_exe}" ]] || return 1

  now_lstart=$(_mac_ops_orphan_lstart "${pid}")
  [[ -n "${now_lstart}" && "${now_lstart}" == "${recorded_lstart}" ]] || return 1

  now_exe=$(_mac_ops_orphan_exe "${pid}")
  [[ -n "${now_exe}" && "${now_exe}" == "${recorded_exe}" ]] || return 1

  # Same process; does it still qualify? Reclassify it on a fresh row.
  _mac_ops_orphan_reclassify "${pid}" "${recorded_exe}" || return 5

  return 0
}

# -----------------------------------------------------------------------------
# Internal: Fresh `ps` row / children of a live PID (read-only, empty if gone)
# Row format: pid ppid uid tty etime rss comm
# Usage: _mac_ops_orphan_fresh_row <pid> ; _mac_ops_orphan_fresh_kids <pid>
# -----------------------------------------------------------------------------
_mac_ops_orphan_fresh_row() {
  ps -o pid=,ppid=,uid=,tty=,etime=,rss=,comm= -p "${1}" 2>/dev/null
}

_mac_ops_orphan_fresh_kids() {
  pgrep -P "${1}" 2>/dev/null
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Replace the snapshot entry of a PID with a fresh row (and its
# current children, and the current launchd list), then run the full
# classification on it again.
# Return 0 if it is still a candidate; _MAC_OPS_ORPHAN_REASON says why not.
# Usage: _mac_ops_orphan_reclassify <pid> <recorded_executable>
# -----------------------------------------------------------------------------
_mac_ops_orphan_reclassify() {
  local pid="${1}" recorded_exe="${2}"
  local row="" rpid="" ppid="" uid="" tty="" etime="" rss="" comm=""
  local kids="" kid=""

  row=$(_mac_ops_orphan_fresh_row "${pid}")
  row="${row%%$'\n'*}"
  read -r rpid ppid uid tty etime rss comm <<< "${row}"
  if [[ "${rpid}" != "${pid}" || ! "${ppid}" =~ ^[0-9]+$ || "${comm}" != "${recorded_exe}" ]]; then
    _MAC_OPS_ORPHAN_REASON="no fresh process table row with the recorded executable"
    return 1
  fi

  _MAC_OPS_ORPHAN_PPID[${pid}]="${ppid}"
  _MAC_OPS_ORPHAN_UID[${pid}]="${uid}"
  _MAC_OPS_ORPHAN_TTY[${pid}]="${tty}"
  _MAC_OPS_ORPHAN_ETIME[${pid}]="${etime}"
  _MAC_OPS_ORPHAN_RSS[${pid}]="${rss}"
  _MAC_OPS_ORPHAN_EXE[${pid}]="${comm}"

  while IFS= read -r kid; do
    [[ "${kid}" =~ ^[0-9]+$ ]] && kids+="${kid}"$'\n'
  done <<< "$(_mac_ops_orphan_fresh_kids "${pid}")"
  _MAC_OPS_ORPHAN_KIDS[${pid}]="${kids}"

  _mac_ops_orphan_load_launchd

  _mac_ops_orphan_classify "${pid}"
}

# -----------------------------------------------------------------------------
# Internal: The only place of this module that sends a signal (SIGTERM)
# Usage: _mac_ops_orphan_signal_term <pid>
# -----------------------------------------------------------------------------
_mac_ops_orphan_signal_term() {
  kill -TERM "${1}" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Internal: Send SIGTERM to a recorded candidate, if and only if
#   - MAC_OPS_ORPHAN_ACTION is "term"
#   - DRY_RUN is off
#   - the PID is not PID 0/1 and not this shell
#   - the PID still has the recorded start time and executable
# SIGKILL is never sent.
# Return 0 = SIGTERM sent, 1 = refused (stale / invalid), 2 = report mode,
#        3 = DRY_RUN (would send), 4 = signal failed
# Usage: _mac_ops_orphan_terminate <pid> <recorded_lstart> <recorded_executable>
# -----------------------------------------------------------------------------
_mac_ops_orphan_terminate() {
  local pid="${1}" recorded_lstart="${2}" recorded_exe="${3}"

  if [[ "$(_mac_ops_orphan_action)" != "term" ]]; then
    mac_ops_log_debug "Orphan process candidate PID ${pid}: report mode, no signal sent"
    return 2
  fi

  if [[ ! "${pid}" =~ ^[0-9]+$ || ${pid} -le 1 || "${pid}" == "$$" ]]; then
    mac_ops_log_warn "Orphan process candidate PID ${pid}: refused, not a signalable PID"
    return 1
  fi

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will send SIGTERM to orphan process candidate PID ${pid} (${recorded_exe})"
    return 3
  fi

  _mac_ops_orphan_verify "${pid}" "${recorded_lstart}" "${recorded_exe}"
  local verify_rc=$?
  if [[ ${verify_rc} -eq 5 ]]; then
    mac_ops_log_warn "Orphan process candidate PID ${pid} (${recorded_exe}): refused, it no longer qualifies on a fresh process table row: ${_MAC_OPS_ORPHAN_REASON}"
    return 1
  elif [[ ${verify_rc} -ne 0 ]]; then
    mac_ops_log_warn "Orphan process candidate PID ${pid} (${recorded_exe}): refused, it is gone or no longer the listed process (start time/executable changed)"
    return 1
  fi

  mac_ops_log_info "Sending SIGTERM to orphan process candidate PID ${pid} (${recorded_exe}); re-check passed: same start time (${recorded_lstart}), same executable, still a candidate on a fresh row"
  if _mac_ops_orphan_signal_term "${pid}"; then
    return 0
  fi
  mac_ops_log_warn "Orphan process candidate PID ${pid} (${recorded_exe}): SIGTERM could not be delivered"
  return 4
}

# -----------------------------------------------------------------------------
# Internal: Human-readable uptime / memory for the report line
# Usage: _mac_ops_orphan_format_uptime <etime> ; _mac_ops_orphan_format_rss <kb>
# -----------------------------------------------------------------------------
_mac_ops_orphan_format_uptime() {
  local hours=""
  hours=$(_mac_ops_parse_etime_hours "${1}" 2>/dev/null)
  if [[ "${hours}" =~ ^[0-9]+$ ]]; then
    print -- "$((hours / 24))d $((hours % 24))h"
  else
    print -- "${1}"
  fi
}

_mac_ops_orphan_format_rss() {
  local kb="${1}"
  if [[ "${kb}" =~ ^[0-9]+$ ]]; then
    print -- "$((kb / 1024)).$(((kb % 1024) * 10 / 1024)) MB"
  else
    print -- "unknown"
  fi
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
