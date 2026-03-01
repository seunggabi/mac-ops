# =============================================================================
# mac-ops: Trash management
# Safe file movement, JSON index metadata, expire/restore/list features
# =============================================================================

# Index file location (centralized JSON metadata)
MAC_OPS_INDEX_FILE="${MAC_OPS_TRASH_DIR}/.index.json"

# Global associative arrays for in-memory index
typeset -gA _MAC_OPS_IDX_ORIG
typeset -gA _MAC_OPS_IDX_TRASH
typeset -gA _MAC_OPS_IDX_REASON
typeset -gA _MAC_OPS_IDX_MODULE
typeset -gA _MAC_OPS_IDX_TIME
typeset -gA _MAC_OPS_IDX_SIZE
typeset -gA _MAC_OPS_IDX_EXPIRE
typeset -ga _MAC_OPS_IDX_KEYS

# Index mutex lock directory (mkdir is atomic — safe for parallel subshells)
MAC_OPS_INDEX_LOCK_DIR="${MAC_OPS_TRASH_DIR}/.index.lock"

# =============================================================================
# JSON index helper functions
# =============================================================================

# -----------------------------------------------------------------------------
# Acquire a mutex lock on the JSON index file (spin-wait, max ~3 seconds)
# Usage: _mac_ops_index_lock
# -----------------------------------------------------------------------------
_mac_ops_index_lock() {
  local retries=0
  while ! mkdir "${MAC_OPS_INDEX_LOCK_DIR}" 2>/dev/null; do
    retries=$((retries + 1))
    if [[ ${retries} -gt 30 ]]; then
      # Stale lock guard: if the lock directory is older than 60s, force-remove it
      local lock_mtime
      lock_mtime=$(stat -f%m "${MAC_OPS_INDEX_LOCK_DIR}" 2>/dev/null)
      if [[ -n "${lock_mtime}" && $(( $(date +%s) - lock_mtime )) -gt 60 ]]; then
        rmdir "${MAC_OPS_INDEX_LOCK_DIR}" 2>/dev/null || true
        mac_ops_log_warn "Removed stale index lock (held > 60s)"
        continue
      fi
      mac_ops_log_warn "Index lock timeout — proceeding without lock"
      return 1
    fi
    sleep 0.1
  done
  return 0
}

# -----------------------------------------------------------------------------
# Release the mutex lock on the JSON index file
# Usage: _mac_ops_index_unlock
# -----------------------------------------------------------------------------
_mac_ops_index_unlock() {
  rmdir "${MAC_OPS_INDEX_LOCK_DIR}" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Escape a string for safe JSON embedding
# Handles backslashes and double quotes
# -----------------------------------------------------------------------------
_mac_ops_json_escape() {
  local str="${1}"
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  print -r -- "${str}"
}

# -----------------------------------------------------------------------------
# Extract a JSON string value from a line like:  "key": "value",
# -----------------------------------------------------------------------------
_mac_ops_json_extract_string() {
  local line="${1}"
  # shellcheck disable=SC2076
  if [[ "${line}" =~ ':[[:space:]]*"(.*)"' ]]; then
    local val="${match[1]}"
    # Unescape
    val="${val//\\\\/\\}"
    val="${val//\\\"/\"}"
    print -r -- "${val}"
  fi
}

# -----------------------------------------------------------------------------
# Extract a JSON number value from a line like:  "key": 12345,
# -----------------------------------------------------------------------------
_mac_ops_json_extract_number() {
  local line="${1}"
  # shellcheck disable=SC2076
  if [[ "${line}" =~ ':[[:space:]]*([0-9]+)' ]]; then
    print -- "${match[1]}"
  fi
}

# -----------------------------------------------------------------------------
# Read the JSON index into global associative arrays
# Creates a default empty index if the file does not exist
# Migrates old .plist metadata on first access
# -----------------------------------------------------------------------------
mac_ops_index_read() {
  # Reset global arrays
  _MAC_OPS_IDX_KEYS=()
  _MAC_OPS_IDX_ORIG=()
  _MAC_OPS_IDX_TRASH=()
  _MAC_OPS_IDX_REASON=()
  _MAC_OPS_IDX_MODULE=()
  _MAC_OPS_IDX_TIME=()
  _MAC_OPS_IDX_SIZE=()
  _MAC_OPS_IDX_EXPIRE=()

  # Migrate old plist metadata if present
  _mac_ops_migrate_plist_to_index

  # Create default if missing
  if [[ ! -f "${MAC_OPS_INDEX_FILE}" ]]; then
    mac_ops_index_write
    return 0
  fi

  # Parse the JSON line by line (format is controlled by us)
  local current_key=""
  local in_entries=false
  local line
  local trimmed

  while IFS= read -r line; do
    # Strip leading whitespace
    trimmed="${line#"${line%%[! ]*}"}"

    # Detect "entries" block start
    if [[ "${trimmed}" == '"entries":'* ]]; then
      in_entries=true
      continue
    fi

    if [[ "${in_entries}" != true ]]; then
      continue
    fi

    # Detect entry key: "hashvalue": {
    if [[ -z "${current_key}" && "${trimmed}" == '"'*'": {' ]]; then
      current_key="${trimmed#\"}"
      current_key="${current_key%%\"*}"
      _MAC_OPS_IDX_KEYS+=("${current_key}")
      continue
    fi

    # Inside an entry, parse fields
    if [[ -n "${current_key}" ]]; then
      case "${trimmed}" in
        '"original_path":'*)
          _MAC_OPS_IDX_ORIG[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
          ;;
        '"trash_path":'*)
          _MAC_OPS_IDX_TRASH[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
          ;;
        '"reason":'*)
          _MAC_OPS_IDX_REASON[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
          ;;
        '"module":'*)
          _MAC_OPS_IDX_MODULE[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
          ;;
        '"timestamp":'*)
          _MAC_OPS_IDX_TIME[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
          ;;
        '"size_bytes":'*)
          _MAC_OPS_IDX_SIZE[${current_key}]="$(_mac_ops_json_extract_number "${trimmed}")"
          ;;
        '"expire_after":'*)
          _MAC_OPS_IDX_EXPIRE[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
          ;;
        '}'*) # matches both '}' and '},'
          current_key=""
          ;;
      esac
    fi
  done < "${MAC_OPS_INDEX_FILE}"

  return 0
}

# -----------------------------------------------------------------------------
# Write the global associative arrays to the JSON index atomically
# Writes to a temp file first, then mv to ensure atomic update
# -----------------------------------------------------------------------------
mac_ops_index_write() {
  local tmp_file="${MAC_OPS_INDEX_FILE}.tmp.$$"

  # Ensure parent directory exists
  mkdir -p "$(dirname "${MAC_OPS_INDEX_FILE}")" 2>/dev/null

  {
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "entries": {'

    local first=true
    local key
    for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
      if [[ "${first}" == true ]]; then
        first=false
      else
        printf ','
      fi
      printf '\n    "%s": {\n' "${key}"
      printf '      "original_path": "%s",\n' "$(_mac_ops_json_escape "${_MAC_OPS_IDX_ORIG[${key}]}")"
      printf '      "trash_path": "%s",\n' "$(_mac_ops_json_escape "${_MAC_OPS_IDX_TRASH[${key}]}")"
      printf '      "reason": "%s",\n' "$(_mac_ops_json_escape "${_MAC_OPS_IDX_REASON[${key}]}")"
      printf '      "module": "%s",\n' "$(_mac_ops_json_escape "${_MAC_OPS_IDX_MODULE[${key}]}")"
      printf '      "timestamp": "%s",\n' "${_MAC_OPS_IDX_TIME[${key}]}"
      printf '      "size_bytes": %s,\n' "${_MAC_OPS_IDX_SIZE[${key}]:-0}"
      printf '      "expire_after": "%s"\n' "${_MAC_OPS_IDX_EXPIRE[${key}]}"
      printf '    }'
    done

    printf '\n  }\n'
    printf '}\n'
  } > "${tmp_file}"

  if ! mv "${tmp_file}" "${MAC_OPS_INDEX_FILE}" 2>/dev/null; then
    rm -f "${tmp_file}"
    mac_ops_log_error "Failed to write index file: ${MAC_OPS_INDEX_FILE}"
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Add an entry to the JSON index
# Usage: mac_ops_index_add <key> <original_path> <trash_path> <reason> \
#          <module> <timestamp> <size_bytes> <expire_after>
# -----------------------------------------------------------------------------
mac_ops_index_add() {
  local key="${1}"
  local original_path="${2}"
  local trash_path="${3}"
  local reason="${4}"
  local module="${5}"
  local timestamp="${6}"
  local size_bytes="${7}"
  local expire_after="${8}"

  # Acquire mutex to prevent race condition during parallel module execution
  _mac_ops_index_lock

  mac_ops_index_read

  _MAC_OPS_IDX_KEYS+=("${key}")
  _MAC_OPS_IDX_ORIG[${key}]="${original_path}"
  _MAC_OPS_IDX_TRASH[${key}]="${trash_path}"
  _MAC_OPS_IDX_REASON[${key}]="${reason}"
  _MAC_OPS_IDX_MODULE[${key}]="${module}"
  _MAC_OPS_IDX_TIME[${key}]="${timestamp}"
  _MAC_OPS_IDX_SIZE[${key}]="${size_bytes}"
  _MAC_OPS_IDX_EXPIRE[${key}]="${expire_after}"

  mac_ops_index_write

  _mac_ops_index_unlock
}

# -----------------------------------------------------------------------------
# Remove an entry from the JSON index by key
# Usage: mac_ops_index_remove <key>
# -----------------------------------------------------------------------------
mac_ops_index_remove() {
  local key="${1}"

  mac_ops_index_read

  # Rebuild keys array without the removed key
  local new_keys=()
  local k
  for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    [[ "${k}" == "${key}" ]] && continue
    new_keys+=("${k}")
  done
  _MAC_OPS_IDX_KEYS=("${new_keys[@]}")

  # Remove from associative arrays
  unset "_MAC_OPS_IDX_ORIG[${key}]"
  unset "_MAC_OPS_IDX_TRASH[${key}]"
  unset "_MAC_OPS_IDX_REASON[${key}]"
  unset "_MAC_OPS_IDX_MODULE[${key}]"
  unset "_MAC_OPS_IDX_TIME[${key}]"
  unset "_MAC_OPS_IDX_SIZE[${key}]"
  unset "_MAC_OPS_IDX_EXPIRE[${key}]"

  mac_ops_index_write
}

# -----------------------------------------------------------------------------
# Get an entry from the JSON index by key
# Loads index and returns 0 if found (data available in global arrays),
# returns 1 if not found
# Usage: mac_ops_index_get <key>
# -----------------------------------------------------------------------------
mac_ops_index_get() {
  local key="${1}"

  mac_ops_index_read

  if [[ -z "${_MAC_OPS_IDX_ORIG[${key}]+_}" ]]; then
    return 1
  fi

  return 0
}

# =============================================================================
# Backward compatibility: migrate old .plist metadata to JSON index
# =============================================================================
_mac_ops_migrate_plist_to_index() {
  # Skip if metadata directory does not exist or has no plist files
  [[ ! -d "${MAC_OPS_META_DIR}" ]] && return 0

  local plist_files
  # shellcheck disable=SC1036
  plist_files=("${MAC_OPS_META_DIR}"/*.plist(N))
  [[ ${#plist_files} -eq 0 ]] && return 0

  # Load existing index if present (without triggering migration again)
  local current_key=""
  local in_entries=false
  local line
  local trimmed

  if [[ -f "${MAC_OPS_INDEX_FILE}" ]]; then
    while IFS= read -r line; do
      trimmed="${line#"${line%%[! ]*}"}"
      if [[ "${trimmed}" == '"entries":'* ]]; then
        in_entries=true
        continue
      fi
      if [[ "${in_entries}" != true ]]; then
        continue
      fi
      if [[ -z "${current_key}" && "${trimmed}" == '"'*'": {' ]]; then
        current_key="${trimmed#\"}"
        current_key="${current_key%%\"*}"
        _MAC_OPS_IDX_KEYS+=("${current_key}")
        continue
      fi
      if [[ -n "${current_key}" ]]; then
        case "${trimmed}" in
          '"original_path":'*)
            _MAC_OPS_IDX_ORIG[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
            ;;
          '"trash_path":'*)
            _MAC_OPS_IDX_TRASH[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
            ;;
          '"reason":'*)
            _MAC_OPS_IDX_REASON[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
            ;;
          '"module":'*)
            _MAC_OPS_IDX_MODULE[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
            ;;
          '"timestamp":'*)
            _MAC_OPS_IDX_TIME[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
            ;;
          '"size_bytes":'*)
            _MAC_OPS_IDX_SIZE[${current_key}]="$(_mac_ops_json_extract_number "${trimmed}")"
            ;;
          '"expire_after":'*)
            _MAC_OPS_IDX_EXPIRE[${current_key}]="$(_mac_ops_json_extract_string "${trimmed}")"
            ;;
          '}'*) # matches both '}' and '},'
            current_key=""
            ;;
        esac
      fi
    done < "${MAC_OPS_INDEX_FILE}"
  fi

  local migrated=0
  local meta_file
  local meta_status=""
  local key=""
  local orig="" trash="" reason="" module="" moved="" size="" expires=""

  for meta_file in "${plist_files[@]}"; do
    [[ ! -f "${meta_file}" ]] && continue

    meta_status=$(plutil -extract Status raw "${meta_file}" 2>/dev/null)
    [[ "${meta_status}" != "completed" ]] && continue

    # Derive key from plist filename (without .plist extension)
    key=$(basename "${meta_file}" .plist)

    # Skip if this key already exists in the index
    if [[ -n "${_MAC_OPS_IDX_ORIG[${key}]+_}" ]]; then
      rm -f "${meta_file}"
      continue
    fi

    # Extract fields from plist
    orig=$(plutil -extract OriginalPath raw "${meta_file}" 2>/dev/null)
    trash=$(plutil -extract TrashPath raw "${meta_file}" 2>/dev/null)
    reason=$(plutil -extract Reason raw "${meta_file}" 2>/dev/null)
    module=$(plutil -extract Module raw "${meta_file}" 2>/dev/null)
    moved=$(plutil -extract MovedAt raw "${meta_file}" 2>/dev/null)
    size=$(plutil -extract SizeBytes raw "${meta_file}" 2>/dev/null || print 0)
    expires=$(plutil -extract ExpiresAt raw "${meta_file}" 2>/dev/null)

    # Add to in-memory arrays
    _MAC_OPS_IDX_KEYS+=("${key}")
    _MAC_OPS_IDX_ORIG[${key}]="${orig}"
    _MAC_OPS_IDX_TRASH[${key}]="${trash}"
    _MAC_OPS_IDX_REASON[${key}]="${reason}"
    _MAC_OPS_IDX_MODULE[${key}]="${module}"
    _MAC_OPS_IDX_TIME[${key}]="${moved}"
    _MAC_OPS_IDX_SIZE[${key}]="${size}"
    _MAC_OPS_IDX_EXPIRE[${key}]="${expires}"

    # Remove old plist file
    rm -f "${meta_file}"
    migrated=$((migrated + 1))
  done

  if [[ ${migrated} -gt 0 ]]; then
    mac_ops_index_write
    mac_ops_log_info "Migrated ${migrated} plist entries to JSON index"
  fi

  return 0
}

# =============================================================================
# Main trash operations (using JSON index)
# =============================================================================

# -----------------------------------------------------------------------------
# Move file/directory to trash
# Usage: mac_ops_trash_move <source_path> <reason> <module_name>
# -----------------------------------------------------------------------------
mac_ops_trash_move() {
  local source_path="${1}"
  local reason="${2}"
  local module_name="${3}"

  # Validate arguments
  if [[ -z "${source_path}" || -z "${reason}" || -z "${module_name}" ]]; then
    mac_ops_log_error "Usage: mac_ops_trash_move <path> <reason> <module_name>"
    return 1
  fi

  # Check if source exists
  if [[ ! -e "${source_path}" ]]; then
    mac_ops_log_error "Source does not exist: ${source_path}"
    return 1
  fi

  # Convert to absolute path
  local abs_source
  abs_source=$(cd "$(dirname "${source_path}")" 2>/dev/null && print -- "${PWD}/$(basename "${source_path}")")
  if [[ -z "${abs_source}" ]]; then
    mac_ops_log_error "Failed to convert path: ${source_path}"
    return 1
  fi

  # Check if same volume
  if ! mac_ops_is_same_volume "${abs_source}" "${MAC_OPS_TRASH_DIR}"; then
    mac_ops_log_error "Cannot move files from different volume to trash: ${abs_source}"
    return 1
  fi

  # DRY_RUN mode
  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will move to trash: ${abs_source} (reason: ${reason})"
    return 0
  fi

  # Target path in trash (preserve original path structure)
  local trash_path="${MAC_OPS_TRASH_DIR}${abs_source}"
  local trash_parent
  trash_parent=$(dirname "${trash_path}")

  # Create target directory
  if ! mkdir -p "${trash_parent}" 2>/dev/null; then
    mac_ops_log_error "Failed to create trash directory: ${trash_parent}"
    return 1
  fi

  # Add timestamp suffix if file already exists at same path
  if [[ -e "${trash_path}" ]]; then
    local ts_suffix
    ts_suffix=$(date '+%Y%m%d_%H%M%S')
    trash_path="${trash_path}.${ts_suffix}"
  fi

  # Calculate file size
  local size_bytes
  size_bytes=$(mac_ops_get_dir_size "${abs_source}")

  # Timestamps
  local now_iso
  now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local expires_iso
  expires_iso=$(date -u -v+"${MAC_OPS_TRASH_RETENTION_HOURS}"H '+%Y-%m-%dT%H:%M:%SZ')

  # Index entry key: sha256 hash of source path + timestamp
  local path_hash
  path_hash=$(print -n "${abs_source}" | shasum -a 256 | cut -d' ' -f1)
  local meta_ts
  meta_ts=$(date '+%Y%m%d%H%M%S')
  local entry_key="${path_hash}_${meta_ts}"

  # Execute move
  if ! mv "${abs_source}" "${trash_path}" 2>/dev/null; then
    mac_ops_log_error "Failed to move file: ${abs_source} -> ${trash_path}"
    return 1
  fi

  # Add entry to JSON index after successful move
  mac_ops_index_add "${entry_key}" \
    "${abs_source}" "${trash_path}" "${reason}" "${module_name}" \
    "${now_iso}" "${size_bytes}" "${expires_iso}"

  mac_ops_log_info "Moved to trash: ${abs_source} (${size_bytes} bytes, reason: ${reason})"
  return 0
}

# -----------------------------------------------------------------------------
# Permanently delete expired items
# Process entries where expire_after is before current time
# -----------------------------------------------------------------------------
mac_ops_trash_expire() {
  local now_epoch
  now_epoch=$(date +%s)
  local deleted_count=0
  local freed_bytes=0

  mac_ops_index_read

  # Collect keys to remove (cannot modify arrays during iteration)
  local remove_keys=()
  local key
  local expires_at=""
  local expires_epoch=""
  local trash_path=""
  local size_bytes=0

  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    expires_at="${_MAC_OPS_IDX_EXPIRE[${key}]}"
    [[ -z "${expires_at}" ]] && continue

    # Convert ISO8601 -> epoch
    expires_epoch=$(date -jf '%Y-%m-%dT%H:%M:%SZ' "${expires_at}" '+%s' 2>/dev/null)
    [[ -z "${expires_epoch}" ]] && continue

    # Check if expired
    if [[ ${now_epoch} -ge ${expires_epoch} ]]; then
      trash_path="${_MAC_OPS_IDX_TRASH[${key}]}"
      size_bytes="${_MAC_OPS_IDX_SIZE[${key}]:-0}"

      # Permanently delete trash file (guard: must be inside MAC_OPS_TRASH_DIR)
      if [[ -n "${trash_path}" && "${trash_path}" == "${MAC_OPS_TRASH_DIR}/"* && -e "${trash_path}" ]]; then
        rm -rf "${trash_path}" 2>/dev/null
        freed_bytes=$((freed_bytes + size_bytes))
      fi

      remove_keys+=("${key}")
      deleted_count=$((deleted_count + 1))
    fi
  done

  # Remove expired entries from index
  if [[ ${#remove_keys} -gt 0 ]]; then
    local rk
    local new_keys
    local k
    for rk in "${remove_keys[@]}"; do
      # Rebuild keys array without removed key
      new_keys=()
      for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
        [[ "${k}" == "${rk}" ]] && continue
        new_keys+=("${k}")
      done
      _MAC_OPS_IDX_KEYS=("${new_keys[@]}")

      unset "_MAC_OPS_IDX_ORIG[${rk}]"
      unset "_MAC_OPS_IDX_TRASH[${rk}]"
      unset "_MAC_OPS_IDX_REASON[${rk}]"
      unset "_MAC_OPS_IDX_MODULE[${rk}]"
      unset "_MAC_OPS_IDX_TIME[${rk}]"
      unset "_MAC_OPS_IDX_SIZE[${rk}]"
      unset "_MAC_OPS_IDX_EXPIRE[${rk}]"
    done

    mac_ops_index_write
  fi

  # Clean up empty directories
  find "${MAC_OPS_TRASH_DIR}" -type d -empty -delete 2>/dev/null

  local freed_mb=$((freed_bytes / 1048576))
  mac_ops_log_info "Expiration completed: ${deleted_count} items deleted, ${freed_mb}MB freed"
  return 0
}

# -----------------------------------------------------------------------------
# Restore from trash to original location
# Usage: mac_ops_trash_restore <original_path>
# -----------------------------------------------------------------------------
mac_ops_trash_restore() {
  local original_path="${1}"

  if [[ -z "${original_path}" ]]; then
    mac_ops_log_error "Usage: mac_ops_trash_restore <original_path>"
    return 1
  fi

  # Convert to absolute path (handle directly as path may not exist)
  if [[ "${original_path}" != /* ]]; then
    original_path="${PWD}/${original_path}"
  fi

  # Search index by sha256 prefix of original path
  local path_hash
  path_hash=$(print -n "${original_path}" | shasum -a 256 | cut -d' ' -f1)

  mac_ops_index_read

  local found_key=""
  local latest_ts=0
  local key
  local key_ts=""

  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    # Match keys that start with the path hash
    if [[ "${key}" == "${path_hash}_"* ]]; then
      # Extract timestamp from key suffix
      key_ts="${key#${path_hash}_}"
      if [[ ${key_ts} -gt ${latest_ts} ]]; then
        latest_ts=${key_ts}
        found_key="${key}"
      fi
    fi
  done

  if [[ -z "${found_key}" ]]; then
    mac_ops_log_error "Cannot find item to restore: ${original_path}"
    return 1
  fi

  local trash_path="${_MAC_OPS_IDX_TRASH[${found_key}]}"

  if [[ -z "${trash_path}" || ! -e "${trash_path}" ]]; then
    mac_ops_log_error "Trash file does not exist: ${trash_path}"
    # Remove dangling entry
    mac_ops_index_remove "${found_key}"
    return 1
  fi

  # Create parent directory of original location
  local restore_parent
  restore_parent=$(dirname "${original_path}")
  if [[ ! -d "${restore_parent}" ]]; then
    mkdir -p "${restore_parent}" 2>/dev/null
  fi

  # Abort if file already exists at original location
  if [[ -e "${original_path}" ]]; then
    mac_ops_log_error "File already exists at original location: ${original_path}"
    return 1
  fi

  # Execute restore
  if ! mv "${trash_path}" "${original_path}" 2>/dev/null; then
    mac_ops_log_error "Restore failed: ${trash_path} -> ${original_path}"
    return 1
  fi

  # Remove entry from index
  mac_ops_index_remove "${found_key}"

  # Clean up empty directories
  find "${MAC_OPS_TRASH_DIR}" -type d -empty -delete 2>/dev/null

  mac_ops_log_info "Restore completed: ${original_path}"
  return 0
}

# -----------------------------------------------------------------------------
# Display trash list
# Read index and output in table format
# -----------------------------------------------------------------------------
mac_ops_trash_list() {
  mac_ops_index_read

  local count=0

  # Print header
  printf "%-50s %12s %-20s %-20s %s\n" \
    "OriginalPath" "Size" "MovedAt" "ExpiresAt" "Reason"
  printf "%0.s-" {1..120}
  print ""

  local key
  local orig="" size="" moved="" expires="" reason="" human_size=""
  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    orig="${_MAC_OPS_IDX_ORIG[${key}]}"
    size="${_MAC_OPS_IDX_SIZE[${key}]:-0}"
    moved="${_MAC_OPS_IDX_TIME[${key}]}"
    expires="${_MAC_OPS_IDX_EXPIRE[${key}]}"
    reason="${_MAC_OPS_IDX_REASON[${key}]}"

    # Convert size to human readable format
    human_size=$(_mac_ops_human_size "${size}")

    printf "%-50s %12s %-20s %-20s %s\n" \
      "${orig}" "${human_size}" "${moved}" "${expires}" "${reason}"

    count=$((count + 1))
  done

  if [[ ${count} -eq 0 ]]; then
    mac_ops_log_info "Trash is empty"
  else
    print ""
    mac_ops_log_info "Total ${count} items"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Display trash status
# Total size, item count, earliest expiration time
# -----------------------------------------------------------------------------
mac_ops_trash_status() {
  mac_ops_index_read

  local total_bytes=0
  local item_count=0
  local earliest_expires=""
  local earliest_epoch=999999999999
  local key
  local size=0
  local expires=""
  local exp_epoch=""

  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    size="${_MAC_OPS_IDX_SIZE[${key}]:-0}"
    total_bytes=$((total_bytes + size))
    item_count=$((item_count + 1))

    expires="${_MAC_OPS_IDX_EXPIRE[${key}]}"
    if [[ -n "${expires}" ]]; then
      exp_epoch=$(date -jf '%Y-%m-%dT%H:%M:%SZ' "${expires}" '+%s' 2>/dev/null)
      if [[ -n "${exp_epoch}" && ${exp_epoch} -lt ${earliest_epoch} ]]; then
        earliest_epoch=${exp_epoch}
        earliest_expires="${expires}"
      fi
    fi
  done

  local human_total
  human_total=$(_mac_ops_human_size "${total_bytes}")

  print "=== mac-ops Trash Status ==="
  print "Total items: ${item_count}"
  print "Total size:  ${human_total}"
  if [[ -n "${earliest_expires}" ]]; then
    print "Next expire: ${earliest_expires}"
  else
    print "Next expire: None"
  fi

  return 0
}

# =============================================================================
# Internal helper functions
# =============================================================================

# Convert bytes to human readable units
_mac_ops_human_size() {
  local bytes="${1:-0}"

  if [[ ${bytes} -ge 1073741824 ]]; then
    printf "%.1fGB" "$((bytes * 10 / 1073741824))e-1"
  elif [[ ${bytes} -ge 1048576 ]]; then
    printf "%.1fMB" "$((bytes * 10 / 1048576))e-1"
  elif [[ ${bytes} -ge 1024 ]]; then
    printf "%.1fKB" "$((bytes * 10 / 1024))e-1"
  else
    printf "%dB" "${bytes}"
  fi
}
