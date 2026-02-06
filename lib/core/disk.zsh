# =============================================================================
# mac-ops: Disk space monitoring
# Usage query, space check, emergency purge, volume comparison
# =============================================================================

# -----------------------------------------------------------------------------
# Return current disk usage percentage
# Based on root volume (/)
# -----------------------------------------------------------------------------
mac_ops_get_disk_usage() {
  local usage
  usage=$(df -h / | tail -1 | awk '{gsub(/%/,"",$5); print $5}')

  if [[ -z "${usage}" || ! "${usage}" =~ ^[0-9]+$ ]]; then
    mac_ops_log_error "Failed to query disk usage"
    return 1
  fi

  print -- "${usage}"
  return 0
}

# -----------------------------------------------------------------------------
# Return remaining disk space in bytes
# Based on root volume (/), convert 512-byte blocks -> bytes
# -----------------------------------------------------------------------------
mac_ops_get_disk_available() {
  local available_blocks
  available_blocks=$(df / | tail -1 | awk '{print $4}')

  if [[ -z "${available_blocks}" || ! "${available_blocks}" =~ ^[0-9]+$ ]]; then
    mac_ops_log_error "Failed to query available disk space"
    return 1
  fi

  # df uses 512-byte blocks by default
  local available_bytes=$((available_blocks * 512))
  print -- "${available_bytes}"
  return 0
}

# -----------------------------------------------------------------------------
# Check if required disk space is available
# Usage: mac_ops_check_disk_space <required_bytes>
# -----------------------------------------------------------------------------
mac_ops_check_disk_space() {
  local required_bytes="${1}"

  if [[ -z "${required_bytes}" || ! "${required_bytes}" =~ ^[0-9]+$ ]]; then
    mac_ops_log_error "Usage: mac_ops_check_disk_space <required_bytes>"
    return 1
  fi

  local available_bytes
  available_bytes=$(mac_ops_get_disk_available)
  if [[ $? -ne 0 ]]; then
    return 1
  fi

  if [[ ${available_bytes} -lt ${required_bytes} ]]; then
    local required_mb=$((required_bytes / 1048576))
    local available_mb=$((available_bytes / 1048576))
    mac_ops_log_error "Insufficient disk space: required ${required_mb}MB, available ${available_mb}MB"
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Return directory/file size in bytes (using du)
# Usage: mac_ops_get_dir_size <path>
# -----------------------------------------------------------------------------
mac_ops_get_dir_size() {
  local target_path="${1}"

  if [[ -z "${target_path}" || ! -e "${target_path}" ]]; then
    print -- "0"
    return 1
  fi

  local size_bytes
  # du -sk: kilobyte unit, total only
  size_bytes=$(du -sk "${target_path}" 2>/dev/null | awk '{print $1}')

  if [[ -z "${size_bytes}" || ! "${size_bytes}" =~ ^[0-9]+$ ]]; then
    print -- "0"
    return 1
  fi

  # Convert KB -> bytes
  print -- "$((size_bytes * 1024))"
  return 0
}

# -----------------------------------------------------------------------------
# Emergency purge
# Immediately delete expired trash when disk usage is 95% or more
# -----------------------------------------------------------------------------
mac_ops_emergency_purge() {
  local usage
  usage=$(mac_ops_get_disk_usage)
  if [[ $? -ne 0 ]]; then
    return 1
  fi

  if [[ ${usage} -lt 95 ]]; then
    mac_ops_log_debug "Disk usage ${usage}%: emergency purge not needed"
    return 0
  fi

  mac_ops_log_warn "Disk usage ${usage}%: starting emergency purge"

  # Delete expired items
  mac_ops_trash_expire

  # Recheck after deletion
  local new_usage
  new_usage=$(mac_ops_get_disk_usage)
  mac_ops_log_info "Emergency purge completed: ${usage}% -> ${new_usage}%"

  return 0
}

# -----------------------------------------------------------------------------
# Check if two paths are on same volume
# Usage: mac_ops_is_same_volume <path1> <path2>
# Return 0 if same volume, 1 if different
# -----------------------------------------------------------------------------
mac_ops_is_same_volume() {
  local path1="${1}"
  local path2="${2}"

  if [[ -z "${path1}" || -z "${path2}" ]]; then
    mac_ops_log_error "Usage: mac_ops_is_same_volume <path1> <path2>"
    return 1
  fi

  # Navigate up to nearest existing parent directory
  local check1="${path1}"
  while [[ ! -e "${check1}" && "${check1}" != "/" ]]; do
    check1=$(dirname "${check1}")
  done

  local check2="${path2}"
  while [[ ! -e "${check2}" && "${check2}" != "/" ]]; do
    check2=$(dirname "${check2}")
  done

  # Compare mount points using df
  local vol1 vol2
  vol1=$(df "${check1}" 2>/dev/null | tail -1 | awk '{print $1}')
  vol2=$(df "${check2}" 2>/dev/null | tail -1 | awk '{print $1}')

  if [[ -z "${vol1}" || -z "${vol2}" ]]; then
    mac_ops_log_error "Failed to query volume information"
    return 1
  fi

  if [[ "${vol1}" != "${vol2}" ]]; then
    mac_ops_log_debug "Different volumes: ${path1}(${vol1}) != ${path2}(${vol2})"
    return 1
  fi

  return 0
}
