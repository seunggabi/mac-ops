# =============================================================================
# mac-ops: Safety system
# Whitelist, protected processes, size guard, SIP check
# =============================================================================

# --- Paths that must never be touched ---
MAC_OPS_WHITELIST=(
  "/System"
  "/bin"
  "/sbin"
  "/usr"
  "/Applications/App Store.app"
  "/Applications/Automator.app"
  "/Applications/Calculator.app"
  "/Applications/Calendar.app"
  "/Applications/Chess.app"
  "/Applications/Contacts.app"
  "/Applications/Dashboard.app"
  "/Applications/Dictionary.app"
  "/Applications/FaceTime.app"
  "/Applications/Finder.app"
  "/Applications/Font Book.app"
  "/Applications/Home.app"
  "/Applications/Image Capture.app"
  "/Applications/Launchpad.app"
  "/Applications/Mail.app"
  "/Applications/Maps.app"
  "/Applications/Messages.app"
  "/Applications/Migration Assistant.app"
  "/Applications/Music.app"
  "/Applications/News.app"
  "/Applications/Notes.app"
  "/Applications/Photo Booth.app"
  "/Applications/Photos.app"
  "/Applications/Podcasts.app"
  "/Applications/Preview.app"
  "/Applications/QuickTime Player.app"
  "/Applications/Reminders.app"
  "/Applications/Safari.app"
  "/Applications/Shortcuts.app"
  "/Applications/Siri.app"
  "/Applications/Stickies.app"
  "/Applications/Stocks.app"
  "/Applications/System Preferences.app"
  "/Applications/System Settings.app"
  "/Applications/TV.app"
  "/Applications/TextEdit.app"
  "/Applications/Time Machine.app"
  "/Applications/Utilities"
  "${HOME}/Library/Keychains"
  "${HOME}/Library/Preferences"
  "${HOME}/Documents"
  "${HOME}/Desktop"
  "${HOME}/Downloads"
  "/Library/LaunchDaemons"
  "/Library/LaunchAgents"
)

# --- Self-protection: the tool's own state and companion tools' data ---
# Resolved at check time (HOME / MAC_OPS_HOME may change after sourcing);
# a leading "~/" means ${HOME}. ${MAC_OPS_HOME} is always protected too.
# Entries protect the directory itself and everything below it.
# Companion/cleaner trash dirs: add entries here only with a reason.
#   ~/.mac-optimize   record directory of the companion mac-optimize tool
#   ~/.mole/trash     trash of the Mole cleaner (recoverable items)
#   /tmp/<root dirs>  mac-optimize parks recoverable items at /tmp/Users etc.
# shellcheck disable=SC2088  # literal "~/" is expanded to ${HOME} at check time
MAC_OPS_SELF_PROTECTED_EXTRA=(
  "~/.mac-optimize"
  "~/.mole/trash"
  "/tmp/Users"
  "/tmp/Library"
  "/tmp/Applications"
  "/tmp/usr"
  "/tmp/opt"
  "/tmp/private"
  "/private/tmp/Users"
  "/private/tmp/Library"
  "/private/tmp/Applications"
  "/private/tmp/usr"
  "/private/tmp/opt"
  "/private/tmp/private"
)

# --- Processes that must never be terminated ---
MAC_OPS_PROTECTED_PROCESSES=(
  "kernel_task"
  "launchd"
  "WindowServer"
  "loginwindow"
  "SystemUIServer"
  "Finder"
  "cfprefsd"
  "mds"
  "mds_stores"
  "Dock"
  "coreaudiod"
  "opendirectoryd"
)

# --- Size limits ---
MAC_OPS_MAX_SINGLE_FILE_BYTES=${MAC_OPS_MAX_SINGLE_FILE_BYTES:-2147483648}   # 2GB (setting MaxSingleFileBytes)
MAC_OPS_MAX_BATCH_BYTES=10737418240        # 10GB

# -----------------------------------------------------------------------------
# Self-protection match: 0 if path is (under) the tool's own home or a
# companion tool's directory. Compares the lexically normalized path and the
# symlink-resolved path (:A also collapses ".." and trailing slashes, even for
# non-existent paths) against each protected entry in both forms.
# Usage: _mac_ops_is_self_protected <path>   (sets REPLY to the matching rule)
# -----------------------------------------------------------------------------
_mac_ops_is_self_protected() {
  local raw="${1}" cand rule resolved_rule entry
  local -a cands rules
  cands=("${raw:A}" "${raw}")
  rules=("${MAC_OPS_SELF_PROTECTED_EXTRA[@]}")
  [[ -n "${MAC_OPS_HOME}" ]] && rules+=("${MAC_OPS_HOME}")
  for entry in "${rules[@]}"; do
    rule="${entry/#\~\//${HOME}/}"
    rule="${rule%/}"
    resolved_rule="${rule:A}"
    for cand in "${cands[@]}"; do
      cand="${cand//\/\///}"
      [[ "${cand}" == "/" ]] || cand="${cand%/}"
      if [[ "${cand}" == "${rule}" || "${cand}" == "${rule}/"* \
        || "${cand}" == "${resolved_rule}" || "${cand}" == "${resolved_rule}/"* ]]; then
        REPLY="${rule}"
        return 0
      fi
    done
  done
  return 1
}

# -----------------------------------------------------------------------------
# Check path safety
# Return 1 if in whitelist (dangerous), 0 if safe
# Usage: mac_ops_is_path_safe <path>
# -----------------------------------------------------------------------------
mac_ops_is_path_safe() {
  local target_path="${1}"

  if [[ -z "${target_path}" ]]; then
    mac_ops_log_error "Path not specified"
    return 1
  fi

  # Normalize to absolute path
  local resolved_path
  if [[ -e "${target_path}" ]]; then
    # Use realpath if available, otherwise manual resolution
    resolved_path=$(realpath "${target_path}" 2>/dev/null)
    if [[ -z "${resolved_path}" ]]; then
      resolved_path=$(cd "$(dirname "${target_path}")" 2>/dev/null && print -- "${PWD}/$(basename "${target_path}")")
    fi
  else
    # Use non-existent path as-is
    resolved_path="${target_path}"
  fi

  # Remove double slashes (normalize paths under root)
  resolved_path="${resolved_path//\/\///}"

  # Check if path is a symlink and resolve target
  if [[ -L "${target_path}" ]]; then
    local symlink_target
    symlink_target=$(readlink -f "${target_path}" 2>/dev/null || readlink "${target_path}" 2>/dev/null)
    if [[ -n "${symlink_target}" && "${symlink_target}" != "${resolved_path}" ]]; then
      mac_ops_log_warn "Symlink detected: ${target_path} -> ${symlink_target}"
      # Check symlink target against whitelist too
      for protected in "${MAC_OPS_WHITELIST[@]}"; do
        if [[ "${symlink_target}" == "${protected}" || "${symlink_target}" == "${protected}/"* ]]; then
          mac_ops_log_warn "Symlink target is a protected path: ${symlink_target} (rule: ${protected})"
          return 1
        fi
      done
    fi
  fi

  # Iterate through whitelist
  for protected in "${MAC_OPS_WHITELIST[@]}"; do
    # If exact match or subpath
    if [[ "${resolved_path}" == "${protected}" || "${resolved_path}" == "${protected}/"* ]]; then
      mac_ops_log_warn "Protected path: ${resolved_path} (rule: ${protected})"
      return 1
    fi
  done

  # Self-protection (tool home, companion tool dirs): the raw input is also
  # checked so ".." components and symlinks cannot slip past
  if _mac_ops_is_self_protected "${target_path}"; then
    mac_ops_log_warn "Protected path: ${target_path} (self-protection rule: ${REPLY})"
    return 1
  fi

  # Protect root directory itself
  if [[ "${resolved_path}" == "/" ]]; then
    mac_ops_log_warn "Root directory is protected"
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Check protected process
# Return 1 if protected process, 0 otherwise
# Usage: mac_ops_is_process_protected <process_name>
# -----------------------------------------------------------------------------
mac_ops_is_process_protected() {
  local process_name="${1}"

  if [[ -z "${process_name}" ]]; then
    mac_ops_log_error "Process name not specified"
    return 1
  fi

  for protected in "${MAC_OPS_PROTECTED_PROCESSES[@]}"; do
    if [[ "${process_name}" == "${protected}" ]]; then
      mac_ops_log_warn "Protected process: ${process_name}"
      return 1
    fi
  done

  return 0
}

# -----------------------------------------------------------------------------
# Check size guard
# Return 1 if file exceeds 2GB (ignored if --force / MAC_OPS_FORCE=true)
# Usage: mac_ops_check_size_guard <path>
# -----------------------------------------------------------------------------
mac_ops_check_size_guard() {
  local target_path="${1}"

  if [[ -z "${target_path}" || ! -e "${target_path}" ]]; then
    mac_ops_log_error "Path does not exist: ${target_path}"
    return 1
  fi

  local size_bytes
  size_bytes=$(mac_ops_get_dir_size "${target_path}")

  if [[ ${size_bytes} -gt ${MAC_OPS_MAX_SINGLE_FILE_BYTES} ]]; then
    if [[ "${MAC_OPS_FORCE}" == "true" ]]; then
      mac_ops_log_warn "Size guard exceeded (${size_bytes} bytes) but continuing with --force mode: ${target_path}"
      return 0
    fi
    local size_gb=$(( size_bytes / 1073741824 ))
    mac_ops_log_error "Size guard: ${target_path} (${size_gb}GB) exceeds 2GB limit. Use --force to override."
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Check SIP (System Integrity Protection) protected path
# Return 1 if SIP protected path, 0 otherwise
# Usage: mac_ops_check_sip <path>
# -----------------------------------------------------------------------------
mac_ops_check_sip() {
  local target_path="${1}"

  if [[ -z "${target_path}" ]]; then
    mac_ops_log_error "Path not specified"
    return 1
  fi

  # SIP protected path list
  local sip_paths=(
    "/System"
    "/usr"
    "/bin"
    "/sbin"
    "/var"
    "/Applications/Utilities"
  )

  # /usr/local is not SIP protected
  if [[ "${target_path}" == "/usr/local"* ]]; then
    return 0
  fi

  for sip_path in "${sip_paths[@]}"; do
    if [[ "${target_path}" == "${sip_path}" || "${target_path}" == "${sip_path}/"* ]]; then
      mac_ops_log_error "SIP protected path: ${target_path}"
      return 1
    fi
  done

  return 0
}
