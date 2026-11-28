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
typeset -gA _MAC_OPS_IDX_SOURCE
typeset -gA _MAC_OPS_IDX_ORIGTIME
typeset -ga _MAC_OPS_IDX_KEYS

# Index lock file (fcntl lock via "zsystem flock"; the file itself is never
# removed). The kernel releases the lock when its owner exits, so a lock can
# neither go stale nor be taken away from a live owner.
MAC_OPS_INDEX_LOCK_FILE="${MAC_OPS_TRASH_DIR}/.index.flock"

# Lock directory used by earlier versions (ignored, kept out of reconcile)
MAC_OPS_INDEX_LOCK_DIR="${MAC_OPS_TRASH_DIR}/.index.lock"

# Staging area for verified copies (never scanned by reconcile)
MAC_OPS_TRASH_STAGING_DIR="${MAC_OPS_TRASH_DIR}/.staging"

# Processed leftover temp index files are kept here (never deleted)
MAC_OPS_TRASH_RECOVERY_DIR="${MAC_OPS_TRASH_DIR}/.index-recovery"

# Seconds to wait for the index lock before giving up (the caller then fails
# safe: nothing is moved or rewritten without the lock)
MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS=${MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS:-120}

# Re-entrancy depth of the index lock, the PID that holds it and its fd
typeset -gi _MAC_OPS_INDEX_LOCK_DEPTH=0
typeset -g _MAC_OPS_INDEX_LOCK_PID=""
typeset -g _MAC_OPS_INDEX_LOCK_FD=""

# Keys added by reconcile/recovery in the current pass (never purged in it)
typeset -gA _MAC_OPS_RECONCILED_KEYS

# In-memory open-file list (dry-run only: nothing is written to disk)
typeset -g _MAC_OPS_OPEN_FILES_MEM=""
typeset -g _MAC_OPS_OPEN_FILES_MEM_TIME=0

# zsh/system: real PID of a subshell ($$ stays the parent PID in subshells)
#             and "zsystem flock"
# zsh/files:  zf_mv is a plain rename(2) and never falls back to copy + delete
zmodload zsh/system 2>/dev/null || true
zmodload -F zsh/files b:zf_mv 2>/dev/null || true

# =============================================================================
# JSON index helper functions
# =============================================================================

# -----------------------------------------------------------------------------
# PID of the current (sub)shell. Result in REPLY.
# -----------------------------------------------------------------------------
_mac_ops_self_pid() {
  REPLY="${sysparams[pid]:-$$}"
  return 0
}

# -----------------------------------------------------------------------------
# Return 0 in dry-run mode (nothing on disk may change)
# -----------------------------------------------------------------------------
_mac_ops_is_dry_run() {
  [[ "${MAC_OPS_DRY_RUN}" == "true" ]]
}

# -----------------------------------------------------------------------------
# Acquire the index lock
# Usage: if ! _mac_ops_index_lock; then <fail safe>; fi
# Returns 1 on timeout. Callers must NOT touch the index or move files into
# the trash without the lock: unlocked read-modify-write cycles of parallel
# modules overwrite each other and silently drop entries.
#
# The lock is an fcntl lock on MAC_OPS_INDEX_LOCK_FILE ("zsystem flock").
# It belongs to the process: a forked subshell does not hold its parent's
# lock (it inherits the depth counter, so the holder PID is checked too) and
# the kernel drops it when the owner exits. There is no stale-lock takeover,
# so two processes can never both hold it.
# The lock file is never opened or closed elsewhere while the lock is held
# (closing any descriptor of the file would release an fcntl lock).
#
# Dry-run: no lock is taken and no lock file is created (dry-run only reads;
# index writes are atomic renames, so a read never sees a partial index).
# -----------------------------------------------------------------------------
_mac_ops_index_lock() {
  _mac_ops_self_pid
  local self_pid="${REPLY}"

  if [[ ${_MAC_OPS_INDEX_LOCK_DEPTH} -gt 0 ]]; then
    if [[ "${_MAC_OPS_INDEX_LOCK_PID}" == "${self_pid}" ]]; then
      _MAC_OPS_INDEX_LOCK_DEPTH=$((_MAC_OPS_INDEX_LOCK_DEPTH + 1))
      return 0
    fi
    # Counter inherited through fork: this process does not hold the lock
    _MAC_OPS_INDEX_LOCK_DEPTH=0
    _MAC_OPS_INDEX_LOCK_PID=""
    _MAC_OPS_INDEX_LOCK_FD=""
  fi

  if _mac_ops_is_dry_run; then
    _MAC_OPS_INDEX_LOCK_DEPTH=1
    _MAC_OPS_INDEX_LOCK_PID="${self_pid}"
    _MAC_OPS_INDEX_LOCK_FD=""
    return 0
  fi

  if ! zsystem supports flock 2>/dev/null; then
    mac_ops_log_error "Index lock unavailable: zsh/system 'zsystem flock' is not supported by this zsh"
    return 1
  fi

  if ! mkdir -p "${MAC_OPS_TRASH_DIR}" 2>/dev/null; then
    mac_ops_log_error "Index lock unavailable: cannot create ${MAC_OPS_TRASH_DIR}"
    return 1
  fi
  if [[ ! -f "${MAC_OPS_INDEX_LOCK_FILE}" ]] && ! { : >> "${MAC_OPS_INDEX_LOCK_FILE}"; } 2>/dev/null; then
    mac_ops_log_error "Index lock unavailable: cannot create ${MAC_OPS_INDEX_LOCK_FILE}"
    return 1
  fi

  local lock_fd=""
  if ! zsystem flock -t "${MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS}" -i 0.1 -f lock_fd "${MAC_OPS_INDEX_LOCK_FILE}" 2>/dev/null; then
    mac_ops_log_error "Index lock timeout after ${MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS}s: ${MAC_OPS_INDEX_LOCK_FILE}"
    return 1
  fi

  _MAC_OPS_INDEX_LOCK_FD="${lock_fd}"
  _MAC_OPS_INDEX_LOCK_PID="${self_pid}"
  _MAC_OPS_INDEX_LOCK_DEPTH=1
  return 0
}

# -----------------------------------------------------------------------------
# Release the index lock
# Only releases a lock this process actually holds.
# Usage: _mac_ops_index_unlock
# -----------------------------------------------------------------------------
_mac_ops_index_unlock() {
  if [[ ${_MAC_OPS_INDEX_LOCK_DEPTH} -le 0 ]]; then
    return 0
  fi

  _mac_ops_self_pid
  if [[ "${_MAC_OPS_INDEX_LOCK_PID}" != "${REPLY}" ]]; then
    # Inherited counter of a parent process: nothing to release here
    _MAC_OPS_INDEX_LOCK_DEPTH=0
    _MAC_OPS_INDEX_LOCK_PID=""
    _MAC_OPS_INDEX_LOCK_FD=""
    return 0
  fi

  _MAC_OPS_INDEX_LOCK_DEPTH=$((_MAC_OPS_INDEX_LOCK_DEPTH - 1))
  if [[ ${_MAC_OPS_INDEX_LOCK_DEPTH} -gt 0 ]]; then
    return 0
  fi

  if [[ "${_MAC_OPS_INDEX_LOCK_FD}" =~ ^[0-9]+$ ]]; then
    zsystem flock -u "${_MAC_OPS_INDEX_LOCK_FD}" 2>/dev/null || true
  fi
  _MAC_OPS_INDEX_LOCK_FD=""
  _MAC_OPS_INDEX_LOCK_PID=""
  return 0
}

# -----------------------------------------------------------------------------
# Escape a string for safe JSON embedding (result in REPLY, no subshell)
# Handles backslashes and double quotes
# -----------------------------------------------------------------------------
_mac_ops_json_escape() {
  local str="${1}"
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  REPLY="${str}"
  return 0
}

# -----------------------------------------------------------------------------
# Extract a JSON string value from a line like:  "key": "value",
# Result in REPLY (no subshell: the index is parsed while holding the lock,
# and a fork per field made large indexes take longer than the lock timeout)
# -----------------------------------------------------------------------------
_mac_ops_json_extract_string() {
  local line="${1}"
  local -a match mbegin mend
  REPLY=""
  # shellcheck disable=SC2076
  if [[ "${line}" =~ ':[[:space:]]*"(.*)"' ]]; then
    local val="${match[1]}"
    # Unescape
    val="${val//\\\\/\\}"
    val="${val//\\\"/\"}"
    REPLY="${val}"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Extract a JSON number value from a line like:  "key": 12345,
# Result in REPLY
# -----------------------------------------------------------------------------
_mac_ops_json_extract_number() {
  local line="${1}"
  local -a match mbegin mend
  REPLY=""
  # shellcheck disable=SC2076
  if [[ "${line}" =~ ':[[:space:]]*([0-9]+)' ]]; then
    REPLY="${match[1]}"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Parse an index file and append its entries to the global arrays
# Usage: _mac_ops_index_parse_file <index_file>
# -----------------------------------------------------------------------------
_mac_ops_index_parse_file() {
  local index_file="${1}"
  [[ -f "${index_file}" ]] || return 0

  # Parse the JSON line by line (format is controlled by us)
  local current_key=""
  local in_entries=false
  local line
  local trimmed

  while IFS= read -r line || [[ -n "${line}" ]]; do
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
          _mac_ops_json_extract_string "${trimmed}"
          _MAC_OPS_IDX_ORIG[${current_key}]="${REPLY}"
          ;;
        '"trash_path":'*)
          _mac_ops_json_extract_string "${trimmed}"
          _MAC_OPS_IDX_TRASH[${current_key}]="${REPLY}"
          ;;
        '"reason":'*)
          _mac_ops_json_extract_string "${trimmed}"
          _MAC_OPS_IDX_REASON[${current_key}]="${REPLY}"
          ;;
        '"module":'*)
          _mac_ops_json_extract_string "${trimmed}"
          _MAC_OPS_IDX_MODULE[${current_key}]="${REPLY}"
          ;;
        '"timestamp":'*)
          _mac_ops_json_extract_string "${trimmed}"
          _MAC_OPS_IDX_TIME[${current_key}]="${REPLY}"
          ;;
        '"size_bytes":'*)
          _mac_ops_json_extract_number "${trimmed}"
          _MAC_OPS_IDX_SIZE[${current_key}]="${REPLY}"
          ;;
        '"expire_after":'*)
          _mac_ops_json_extract_string "${trimmed}"
          _MAC_OPS_IDX_EXPIRE[${current_key}]="${REPLY}"
          ;;
        '"source":'*)
          _mac_ops_json_extract_string "${trimmed}"
          _MAC_OPS_IDX_SOURCE[${current_key}]="${REPLY}"
          ;;
        '"original_time":'*)
          _mac_ops_json_extract_string "${trimmed}"
          _MAC_OPS_IDX_ORIGTIME[${current_key}]="${REPLY}"
          ;;
        '}'*) # matches both '}' and '},'
          current_key=""
          ;;
      esac
    fi
  done < "${index_file}"

  return 0
}

# -----------------------------------------------------------------------------
# Clear the in-memory index
# -----------------------------------------------------------------------------
_mac_ops_index_reset() {
  _MAC_OPS_IDX_KEYS=()
  _MAC_OPS_IDX_ORIG=()
  _MAC_OPS_IDX_TRASH=()
  _MAC_OPS_IDX_REASON=()
  _MAC_OPS_IDX_MODULE=()
  _MAC_OPS_IDX_TIME=()
  _MAC_OPS_IDX_SIZE=()
  _MAC_OPS_IDX_EXPIRE=()
  _MAC_OPS_IDX_SOURCE=()
  _MAC_OPS_IDX_ORIGTIME=()
  return 0
}

# -----------------------------------------------------------------------------
# Print the entries of an index file as NUL-separated records (key, original
# path, trash path, reason, module, timestamp, size). Meant to run in a
# subshell, so the index loaded in the caller stays untouched.
# Usage: _mac_ops_index_dump_file <index_file>
# -----------------------------------------------------------------------------
_mac_ops_index_dump_file() {
  _mac_ops_index_reset
  _mac_ops_index_parse_file "${1}"
  local key
  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' "${key}" \
      "${_MAC_OPS_IDX_ORIG[${key}]}" "${_MAC_OPS_IDX_TRASH[${key}]}" \
      "${_MAC_OPS_IDX_REASON[${key}]}" "${_MAC_OPS_IDX_MODULE[${key}]}" \
      "${_MAC_OPS_IDX_TIME[${key}]}" "${_MAC_OPS_IDX_SIZE[${key}]}"
  done
  return 0
}

# -----------------------------------------------------------------------------
# Read the JSON index into global associative arrays. Read-only: takes no
# lock and writes nothing (a missing index is an empty index). Legacy .plist
# metadata that has not been migrated yet is shown in memory, not migrated.
# Used by list-trash, status and lookups.
# -----------------------------------------------------------------------------
mac_ops_index_read() {
  _mac_ops_index_reset
  _mac_ops_index_parse_file "${MAC_OPS_INDEX_FILE}"
  _mac_ops_migrate_plist_to_index memory
  return 0
}

# -----------------------------------------------------------------------------
# Load the index for a read-modify-write cycle. The caller must hold the
# index lock. Migrates legacy .plist metadata into the index first (skipped
# in dry-run, where the legacy entries are only loaded into memory).
# -----------------------------------------------------------------------------
_mac_ops_index_load_locked() {
  if _mac_ops_is_dry_run; then
    mac_ops_index_read
    return 0
  fi

  _mac_ops_index_reset
  _mac_ops_migrate_plist_to_index write || true
  _mac_ops_index_reset
  _mac_ops_index_parse_file "${MAC_OPS_INDEX_FILE}"
  return 0
}

# -----------------------------------------------------------------------------
# Write the global associative arrays to the JSON index atomically
# Writes to a unique temp file first, then renames it over the index.
# The temp name comes from mktemp: "$$" is the PARENT PID inside the parallel
# module subshells, so a "$$"-based name was shared by all of them.
# -----------------------------------------------------------------------------
mac_ops_index_write() {
  if _mac_ops_is_dry_run; then
    mac_ops_log_info "[DRY_RUN] Will write the trash index (${#_MAC_OPS_IDX_KEYS[@]} entries): ${MAC_OPS_INDEX_FILE}"
    return 0
  fi

  # Ensure parent directory exists
  mkdir -p "${MAC_OPS_TRASH_DIR}" 2>/dev/null || true

  local tmp_file=""
  tmp_file=$(mktemp "${MAC_OPS_INDEX_FILE}.tmp.XXXXXX" 2>/dev/null) || tmp_file=""
  if [[ -z "${tmp_file}" ]]; then
    mac_ops_log_error "Failed to create temp index file in: ${MAC_OPS_TRASH_DIR}"
    return 1
  fi

  local write_ok=true
  {
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "entries": {'

    local first=true
    local key
    local esc_orig="" esc_trash="" esc_reason="" esc_module=""
    for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
      if [[ "${first}" == true ]]; then
        first=false
      else
        printf ','
      fi
      _mac_ops_json_escape "${_MAC_OPS_IDX_ORIG[${key}]}"; esc_orig="${REPLY}"
      _mac_ops_json_escape "${_MAC_OPS_IDX_TRASH[${key}]}"; esc_trash="${REPLY}"
      _mac_ops_json_escape "${_MAC_OPS_IDX_REASON[${key}]}"; esc_reason="${REPLY}"
      _mac_ops_json_escape "${_MAC_OPS_IDX_MODULE[${key}]}"; esc_module="${REPLY}"
      printf '\n    "%s": {\n' "${key}"
      printf '      "original_path": "%s",\n' "${esc_orig}"
      printf '      "trash_path": "%s",\n' "${esc_trash}"
      printf '      "reason": "%s",\n' "${esc_reason}"
      printf '      "module": "%s",\n' "${esc_module}"
      printf '      "timestamp": "%s",\n' "${_MAC_OPS_IDX_TIME[${key}]}"
      printf '      "size_bytes": %s,\n' "${_MAC_OPS_IDX_SIZE[${key}]:-0}"
      if [[ -n "${_MAC_OPS_IDX_SOURCE[${key}]}" ]]; then
        _mac_ops_json_escape "${_MAC_OPS_IDX_SOURCE[${key}]}"
        printf '      "source": "%s",\n' "${REPLY}"
      fi
      if [[ -n "${_MAC_OPS_IDX_ORIGTIME[${key}]}" ]]; then
        _mac_ops_json_escape "${_MAC_OPS_IDX_ORIGTIME[${key}]}"
        printf '      "original_time": "%s",\n' "${REPLY}"
      fi
      printf '      "expire_after": "%s"\n' "${_MAC_OPS_IDX_EXPIRE[${key}]}"
      printf '    }'
    done

    printf '\n  }\n'
    printf '}\n' || write_ok=false
  } > "${tmp_file}" 2>/dev/null || write_ok=false

  if [[ "${write_ok}" != true ]] || ! mv -f "${tmp_file}" "${MAC_OPS_INDEX_FILE}" 2>/dev/null; then
    rm -f "${tmp_file}" 2>/dev/null || true
    mac_ops_log_error "Failed to write index file: ${MAC_OPS_INDEX_FILE}"
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Append an entry to the index. The caller must hold the index lock.
# Usage: _mac_ops_index_add_locked <key> <original_path> <trash_path> <reason> \
#          <module> <timestamp> <size_bytes> <expire_after> [source] [original_time]
# Sets REPLY to the key actually used.
# -----------------------------------------------------------------------------
_mac_ops_index_add_locked() {
  local key="${1}"

  _mac_ops_index_load_locked

  # Keys are "<path hash>_<timestamp>": the same path trashed twice within a
  # second would reuse the key and overwrite the first record
  local key_prefix="${key%_*}"
  local key_ts="${key##*_}"
  while [[ -n "${_MAC_OPS_IDX_ORIG[${key}]+_}" && "${key_ts}" =~ ^[0-9]+$ ]]; do
    key_ts=$((key_ts + 1))
    key="${key_prefix}_${key_ts}"
  done

  _MAC_OPS_IDX_KEYS+=("${key}")
  _MAC_OPS_IDX_ORIG[${key}]="${2}"
  _MAC_OPS_IDX_TRASH[${key}]="${3}"
  _MAC_OPS_IDX_REASON[${key}]="${4}"
  _MAC_OPS_IDX_MODULE[${key}]="${5}"
  _MAC_OPS_IDX_TIME[${key}]="${6}"
  _MAC_OPS_IDX_SIZE[${key}]="${7}"
  _MAC_OPS_IDX_EXPIRE[${key}]="${8}"
  _MAC_OPS_IDX_SOURCE[${key}]="${9:-}"
  _MAC_OPS_IDX_ORIGTIME[${key}]="${10:-}"

  if ! mac_ops_index_write; then
    return 1
  fi
  REPLY="${key}"
  return 0
}

# -----------------------------------------------------------------------------
# Add an entry to the JSON index
# Usage: mac_ops_index_add <key> <original_path> <trash_path> <reason> \
#          <module> <timestamp> <size_bytes> <expire_after>
# -----------------------------------------------------------------------------
mac_ops_index_add() {
  # Serialize against parallel modules; never write without the lock
  if ! _mac_ops_index_lock; then
    mac_ops_log_error "Index entry not written (lock unavailable): ${2}"
    return 1
  fi

  local rc=0
  if ! _mac_ops_index_add_locked "$@"; then
    rc=1
  fi

  _mac_ops_index_unlock
  return ${rc}
}

# -----------------------------------------------------------------------------
# Drop keys from the in-memory index (no read, no write)
# Usage: _mac_ops_index_forget <key>...
# -----------------------------------------------------------------------------
_mac_ops_index_forget() {
  local -A drop
  local key
  for key in "$@"; do
    drop[${key}]=1
    unset "_MAC_OPS_IDX_ORIG[${key}]"
    unset "_MAC_OPS_IDX_TRASH[${key}]"
    unset "_MAC_OPS_IDX_REASON[${key}]"
    unset "_MAC_OPS_IDX_MODULE[${key}]"
    unset "_MAC_OPS_IDX_TIME[${key}]"
    unset "_MAC_OPS_IDX_SIZE[${key}]"
    unset "_MAC_OPS_IDX_EXPIRE[${key}]"
    unset "_MAC_OPS_IDX_SOURCE[${key}]"
    unset "_MAC_OPS_IDX_ORIGTIME[${key}]"
  done

  local -a new_keys
  new_keys=()
  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    [[ -n "${drop[${key}]+_}" ]] && continue
    new_keys+=("${key}")
  done
  _MAC_OPS_IDX_KEYS=("${new_keys[@]}")
  return 0
}

# -----------------------------------------------------------------------------
# Remove an entry from the JSON index by key
# Usage: mac_ops_index_remove <key>
# -----------------------------------------------------------------------------
mac_ops_index_remove() {
  local key="${1}"

  if ! _mac_ops_index_lock; then
    mac_ops_log_error "Index entry not removed (lock unavailable): ${key}"
    return 1
  fi

  _mac_ops_index_load_locked
  _mac_ops_index_forget "${key}"

  local rc=0
  if ! mac_ops_index_write; then
    rc=1
  fi

  _mac_ops_index_unlock
  return ${rc}
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
# Usage: _mac_ops_migrate_plist_to_index <memory|write>
#   memory: add legacy entries to the loaded in-memory index only (the index
#           must already be loaded); nothing on disk changes
#   write:  load the index file, add the legacy entries, write the index and
#           only then remove the migrated .plist files. The caller must hold
#           the index lock and must not be in dry-run mode.
# =============================================================================
_mac_ops_migrate_plist_to_index() {
  local mode="${1:-memory}"

  # Skip if metadata directory does not exist or has no plist files
  [[ ! -d "${MAC_OPS_META_DIR}" ]] && return 0

  local plist_files
  # shellcheck disable=SC1036
  plist_files=("${MAC_OPS_META_DIR}"/*.plist(N))
  [[ ${#plist_files} -eq 0 ]] && return 0

  if [[ "${mode}" == "write" ]]; then
    _mac_ops_index_parse_file "${MAC_OPS_INDEX_FILE}"
  fi

  local -a done_files
  done_files=()
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
      done_files+=("${meta_file}")
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
    _MAC_OPS_IDX_SOURCE[${key}]="plist-migration"

    done_files+=("${meta_file}")
    migrated=$((migrated + 1))
  done

  [[ "${mode}" == "write" ]] || return 0

  if [[ ${migrated} -gt 0 ]]; then
    if ! mac_ops_index_write; then
      mac_ops_log_error "Plist migration not completed (index write failed); legacy files kept"
      return 1
    fi
    mac_ops_log_info "Migrated ${migrated} plist entries to JSON index"
  fi

  # The entries are in the written index: the legacy files can go
  for meta_file in "${done_files[@]}"; do
    rm -f "${meta_file}"
  done

  return 0
}

# =============================================================================
# Move primitives (overridable in tests)
# =============================================================================

# -----------------------------------------------------------------------------
# Atomic rename. Uses zsh's zf_mv, which is a plain rename(2): it either moves
# the whole entry or fails, and never degrades to copy + delete the way
# /bin/mv does when the rename is not possible.
# Usage: _mac_ops_trash_rename <source> <destination>
# -----------------------------------------------------------------------------
_mac_ops_trash_rename() {
  if ! whence zf_mv >/dev/null 2>&1; then
    return 1
  fi
  if zf_mv -- "${1}" "${2}" 2>/dev/null; then
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Recursive copy preserving attributes (does not follow symlinks)
# Usage: _mac_ops_trash_copy <source> <destination>
# -----------------------------------------------------------------------------
_mac_ops_trash_copy() {
  if cp -Rp -- "${1}" "${2}" 2>/dev/null; then
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Entry count and total regular-file bytes of a tree. Result in REPLY as
# "<entries> <bytes>". Returns 1 if the tree cannot be read completely.
# Usage: _mac_ops_tree_signature <path>
# -----------------------------------------------------------------------------
_mac_ops_tree_signature() {
  setopt LOCAL_OPTIONS PIPE_FAIL
  local target="${1}"
  local entries="" bytes=""
  REPLY=""

  entries=$(find "${target}" -print 2>/dev/null | wc -l) || return 1
  bytes=$(find "${target}" -type f -exec stat -f%z {} + 2>/dev/null | awk '{ s += $1 } END { printf "%d", s }') || return 1

  entries="${entries//[[:space:]]/}"
  if [[ ! "${entries}" =~ ^[0-9]+$ || ! "${bytes}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  REPLY="${entries} ${bytes}"
  return 0
}

# -----------------------------------------------------------------------------
# Remove a staging directory (guard: must be inside the staging area)
# -----------------------------------------------------------------------------
_mac_ops_trash_remove_staged() {
  local staged="${1}"
  if [[ -n "${staged}" && "${staged}" == "${MAC_OPS_TRASH_STAGING_DIR}/"* ]]; then
    rm -rf -- "${staged}" 2>/dev/null || true
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Copy <source> into the staging area and verify the copy (entry count and
# total size) against the source. On any failure the partial copy is removed
# and 1 is returned; the source is never touched here.
# On success REPLY holds the staged path (inside its own staging directory).
# Usage: _mac_ops_trash_copy_verified <source>
# -----------------------------------------------------------------------------
_mac_ops_trash_copy_verified() {
  local source_path="${1}"
  REPLY=""

  if ! mkdir -p "${MAC_OPS_TRASH_STAGING_DIR}" 2>/dev/null; then
    return 1
  fi

  local stage_dir=""
  stage_dir=$(mktemp -d "${MAC_OPS_TRASH_STAGING_DIR}/copy.XXXXXX" 2>/dev/null) || stage_dir=""
  if [[ -z "${stage_dir}" ]]; then
    return 1
  fi

  local staged="${stage_dir}/${source_path##*/}"

  if ! _mac_ops_trash_copy "${source_path}" "${staged}"; then
    mac_ops_log_error "Copy to trash failed, partial copy removed: ${source_path}"
    _mac_ops_trash_remove_staged "${stage_dir}"
    return 1
  fi

  local sig_source="" sig_copy=""
  if _mac_ops_tree_signature "${source_path}"; then
    sig_source="${REPLY}"
  fi
  if _mac_ops_tree_signature "${staged}"; then
    sig_copy="${REPLY}"
  fi

  if [[ -z "${sig_source}" || "${sig_source}" != "${sig_copy}" ]]; then
    mac_ops_log_error "Copy verification failed (source: '${sig_source}', copy: '${sig_copy}' entries/bytes), partial copy removed: ${source_path}"
    _mac_ops_trash_remove_staged "${stage_dir}"
    REPLY=""
    return 1
  fi

  # Signature of the source at copy time: re-checked right before the source
  # is removed, so writes that land after the copy are not lost
  _MAC_OPS_COPY_SOURCE_SIG="${sig_source}"
  REPLY="${staged}"
  return 0
}

# -----------------------------------------------------------------------------
# Pick a trash path for a new entry. Result in REPLY.
# The caller must hold the index lock and have the index loaded, so the name
# stays free until the rename (renaming onto an existing directory would nest
# the entry inside it).
#
# Every index record must own a distinct, non-nested path: the result does
# not exist, is not an indexed trash path, is not inside one and is not a
# parent directory of one. A path wanted inside an indexed entry (X trashed,
# X recreated, X/sub trashed) is placed under a timestamp-suffixed sibling of
# that entry (X.<ts>/sub); a path that is taken is suffixed itself.
# Usage: _mac_ops_trash_free_path <wanted_trash_path>
# -----------------------------------------------------------------------------
_mac_ops_trash_free_path() {
  local wanted="${1}"

  # Indexed trash paths and their parent directories
  local -A idx_paths idx_ancestors
  local key tp parent
  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    tp="${_MAC_OPS_IDX_TRASH[${key}]}"
    [[ -n "${tp}" ]] || continue
    idx_paths[${tp}]=1
    parent="${tp%/*}"
    while [[ "${parent}" == "${MAC_OPS_TRASH_DIR}/"* && -z "${idx_ancestors[${parent}]+_}" ]]; do
      idx_ancestors[${parent}]=1
      parent="${parent%/*}"
    done
  done

  # Shallowest indexed entry the wanted path would land inside
  local base="${wanted}"
  local rest=""
  parent="${wanted%/*}"
  while [[ "${parent}" == "${MAC_OPS_TRASH_DIR}/"* ]]; do
    if [[ -n "${idx_paths[${parent}]+_}" ]]; then
      base="${parent}"
      rest="${wanted#"${parent}"}"
    fi
    parent="${parent%/*}"
  done

  local candidate="${base}${rest}"
  local ts_suffix="" n=0 taken
  while true; do
    taken=false
    if [[ -e "${candidate}" || -L "${candidate}" \
      || -n "${idx_paths[${candidate}]+_}" || -n "${idx_ancestors[${candidate}]+_}" ]]; then
      taken=true
    else
      parent="${candidate%/*}"
      while [[ "${parent}" == "${MAC_OPS_TRASH_DIR}/"* ]]; do
        if [[ -n "${idx_paths[${parent}]+_}" ]]; then
          taken=true
          break
        fi
        parent="${parent%/*}"
      done
    fi
    [[ "${taken}" == true ]] || break

    if [[ -z "${ts_suffix}" ]]; then
      ts_suffix=$(date '+%Y%m%d_%H%M%S')
      candidate="${base}.${ts_suffix}${rest}"
    else
      n=$((n + 1))
      candidate="${base}.${ts_suffix}_${n}${rest}"
    fi
  done

  if [[ "${candidate}" != "${wanted}" ]]; then
    mac_ops_log_info "Trash path taken or inside another entry, using: ${candidate}"
  fi
  REPLY="${candidate}"
  return 0
}

# =============================================================================
# Open-file detection
# =============================================================================

# -----------------------------------------------------------------------------
# Print the names of all open files ("lsof -Fn" output). Overridable in tests.
# Returns non-zero when lsof is missing or fails.
# -----------------------------------------------------------------------------
_mac_ops_lsof_names() {
  if ! command -v lsof >/dev/null 2>&1; then
    return 127
  fi
  lsof -nP -Fn 2>/dev/null
}

# -----------------------------------------------------------------------------
# Produce the open-file name list ("n/<path>" lines).
# One list is built and shared by every module of a run (lsof per path is far
# too slow); it is rebuilt when older than MAC_OPS_OPEN_FILES_TTL_SECONDS
# (default 60).
#   Normal mode: cached in MAC_OPS_HOME/.tmp/open-files.list, REPLY = its path
#   Dry-run:     the cache file is only read if fresh; otherwise the list is
#                kept in memory (_MAC_OPS_OPEN_FILES_MEM) and REPLY is empty
# Returns 1 when no list can be produced (lsof missing, failing or silent):
# the caller must then treat every path as possibly open.
# -----------------------------------------------------------------------------
_mac_ops_open_files_list() {
  setopt LOCAL_OPTIONS NO_PIPE_FAIL
  local list_dir="${MAC_OPS_HOME}/.tmp"
  local list_file="${list_dir}/open-files.list"
  local ttl="${MAC_OPS_OPEN_FILES_TTL_SECONDS:-60}"
  local now mtime
  local -a rcs
  REPLY=""

  now=$(date +%s)
  if [[ -s "${list_file}" ]]; then
    mtime=$(stat -f%m "${list_file}" 2>/dev/null) || mtime=0
    if [[ "${mtime}" =~ ^[0-9]+$ && $((now - mtime)) -lt ${ttl} ]]; then
      REPLY="${list_file}"
      return 0
    fi
  fi

  if _mac_ops_is_dry_run; then
    if [[ -n "${_MAC_OPS_OPEN_FILES_MEM}" && $((now - _MAC_OPS_OPEN_FILES_MEM_TIME)) -lt ${ttl} ]]; then
      return 0
    fi
    local mem=""
    mem=$(_mac_ops_lsof_names | grep '^n/'; rcs=("${pipestatus[@]}"); exit "${rcs[1]}") || mem=""
    _MAC_OPS_OPEN_FILES_MEM="${mem}"
    _MAC_OPS_OPEN_FILES_MEM_TIME="${now}"
    [[ -n "${mem}" ]] || return 1
    return 0
  fi

  if ! mkdir -p "${list_dir}" 2>/dev/null; then
    return 1
  fi

  local tmp_list=""
  tmp_list=$(mktemp "${list_file}.XXXXXX" 2>/dev/null) || tmp_list=""
  if [[ -z "${tmp_list}" ]]; then
    return 1
  fi

  # A failing or missing lsof gives no usable answer: no list
  _mac_ops_lsof_names | grep '^n/' > "${tmp_list}" 2>/dev/null
  rcs=("${pipestatus[@]}")

  if [[ "${rcs[1]}" != "0" || ! -s "${tmp_list}" ]] || ! mv -f "${tmp_list}" "${list_file}" 2>/dev/null; then
    rm -f "${tmp_list}" 2>/dev/null || true
    return 1
  fi

  REPLY="${list_file}"
  return 0
}

# -----------------------------------------------------------------------------
# Is a path open in a running process? Result in REPLY:
#   open     - the file (or, for a directory, the directory or anything
#              inside it) is open
#   closed   - nothing is open
#   unknown  - the open-file list could not be produced
# Usage: _mac_ops_path_open_state <path>
# -----------------------------------------------------------------------------
_mac_ops_path_open_state() {
  setopt LOCAL_OPTIONS NO_PIPE_FAIL
  local target="${1}"

  if ! _mac_ops_open_files_list; then
    REPLY="unknown"
    return 0
  fi
  local list_file="${REPLY}"

  # lsof prints resolved paths (/private/var/..., not /var/...)
  local real_path="${target:A}"
  local prefix_match=0
  [[ -d "${target}" && ! -L "${target}" ]] && prefix_match=1

  local awk_prog='
      BEGIN { p = ENVIRON["MAC_OPS_NEEDLE"]; q = p "/"; d = ENVIRON["MAC_OPS_PREFIX"] }
      $0 == p || (d == "1" && index($0, q) == 1) { found = 1; exit }
      END { exit found ? 0 : 1 }
    '
  local rc=1
  if [[ -n "${list_file}" ]]; then
    MAC_OPS_NEEDLE="n${real_path}" MAC_OPS_PREFIX="${prefix_match}" LC_ALL=C awk "${awk_prog}" "${list_file}" 2>/dev/null && rc=0
  else
    print -r -- "${_MAC_OPS_OPEN_FILES_MEM}" | MAC_OPS_NEEDLE="n${real_path}" MAC_OPS_PREFIX="${prefix_match}" LC_ALL=C awk "${awk_prog}" 2>/dev/null && rc=0
  fi

  if [[ ${rc} -eq 0 ]]; then
    REPLY="open"
  else
    REPLY="closed"
  fi
  return 0
}

# =============================================================================
# Main trash operations (using JSON index)
# =============================================================================

# -----------------------------------------------------------------------------
# Move file/directory to trash (all-or-nothing)
# Usage: mac_ops_trash_move <source_path> <reason> <module_name>
#
# - Same-volume moves are a single rename(2): atomic, nothing is copied.
# - If the rename is not possible, the source is copied to a staging area,
#   the copy is verified (entry count + total size) and only then renamed
#   into the trash and the source removed. On any failure the source is left
#   untouched and the partial copy is removed.
#   Right before the source is removed it is checked again (entry count +
#   total size); if it changed since the copy, the source is kept and the
#   trashed copy removed.
# - A file, or a directory with anything inside it, that a running process
#   has open is not moved; when that cannot be determined (lsof missing or
#   failing) nothing is moved either (MAC_OPS_TRASH_SKIP_OPEN_DIRS=false
#   disables the check).
# - The rename and its index record happen under the index lock, so the
#   reconcile step never sees a moved-but-not-yet-indexed entry.
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
  abs_source=$(cd "$(dirname "${source_path}")" 2>/dev/null && print -- "${PWD}/$(basename "${source_path}")") || abs_source=""
  if [[ -z "${abs_source}" ]]; then
    mac_ops_log_error "Failed to convert path: ${source_path}"
    return 1
  fi

  # Check if same volume
  if ! mac_ops_is_same_volume "${abs_source}" "${MAC_OPS_TRASH_DIR}"; then
    mac_ops_log_error "Cannot move files from different volume to trash: ${abs_source}"
    return 1
  fi

  # Refuse files and directories that are in use by a running process, and
  # refuse when that cannot be determined (fail closed)
  if [[ "${MAC_OPS_TRASH_SKIP_OPEN_DIRS:-true}" == "true" && ! -L "${abs_source}" ]]; then
    _mac_ops_path_open_state "${abs_source}"
    case "${REPLY}" in
      open)
        mac_ops_log_warn "Not moved, a running process has it open: ${abs_source}"
        return 1
        ;;
      unknown)
        mac_ops_log_error "Not moved, cannot tell whether a running process has it open (lsof missing or failed): ${abs_source}"
        return 1
        ;;
    esac
  fi

  # DRY_RUN mode
  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will move to trash: ${abs_source} (reason: ${reason})"
    return 0
  fi

  # Target path in trash (preserve original path structure)
  local wanted_path="${MAC_OPS_TRASH_DIR}${abs_source}"
  local trash_path=""
  local trash_parent="${wanted_path%/*}"

  # Calculate file size
  local size_bytes
  size_bytes=$(mac_ops_get_dir_size "${abs_source}") || true
  [[ "${size_bytes}" =~ ^[0-9]+$ ]] || size_bytes=0

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

  # --- Fast path: atomic rename + index record under the index lock ---
  if ! _mac_ops_index_lock; then
    mac_ops_log_error "Not moved (index lock unavailable), source left untouched: ${abs_source}"
    return 1
  fi

  # Timestamp suffix if the path is taken, inside or above another entry
  _mac_ops_index_load_locked
  _mac_ops_trash_free_path "${wanted_path}"
  trash_path="${REPLY}"
  trash_parent="${trash_path%/*}"

  if ! mkdir -p "${trash_parent}" 2>/dev/null; then
    _mac_ops_index_unlock
    mac_ops_log_error "Failed to create trash directory: ${trash_parent}"
    return 1
  fi

  if _mac_ops_trash_rename "${abs_source}" "${trash_path}"; then
    if ! _mac_ops_index_add_locked "${entry_key}" \
      "${abs_source}" "${trash_path}" "${reason}" "${module_name}" \
      "${now_iso}" "${size_bytes}" "${expires_iso}"; then
      mac_ops_log_warn "Moved but not indexed (reconcile will re-index it): ${trash_path}"
    fi
    _mac_ops_index_unlock
    mac_ops_log_info "Moved to trash: ${abs_source} (${size_bytes} bytes, reason: ${reason})"
    return 0
  fi

  # --- Slow path: verified copy, without holding the lock while copying ---
  _mac_ops_index_unlock
  mac_ops_log_debug "Rename not possible, falling back to verified copy: ${abs_source}"

  if ! _mac_ops_trash_copy_verified "${abs_source}"; then
    mac_ops_log_error "Failed to move file, source left untouched: ${abs_source} -> ${trash_path}"
    return 1
  fi
  local staged="${REPLY}"
  local stage_dir="${staged%/*}"
  local copy_sig="${_MAC_OPS_COPY_SOURCE_SIG}"

  if ! _mac_ops_index_lock; then
    _mac_ops_trash_remove_staged "${stage_dir}"
    mac_ops_log_error "Not moved (index lock unavailable), source left untouched: ${abs_source}"
    return 1
  fi

  _mac_ops_index_load_locked
  _mac_ops_trash_free_path "${wanted_path}"
  trash_path="${REPLY}"
  if ! mkdir -p "${trash_path%/*}" 2>/dev/null; then
    _mac_ops_trash_remove_staged "${stage_dir}"
    _mac_ops_index_unlock
    mac_ops_log_error "Failed to create trash directory, source left untouched: ${trash_path%/*}"
    return 1
  fi

  if ! _mac_ops_trash_rename "${staged}" "${trash_path}"; then
    _mac_ops_trash_remove_staged "${stage_dir}"
    _mac_ops_index_unlock
    mac_ops_log_error "Failed to move file, source left untouched: ${abs_source} -> ${trash_path}"
    return 1
  fi
  _mac_ops_trash_remove_staged "${stage_dir}"

  local added_key=""
  if _mac_ops_index_add_locked "${entry_key}" \
    "${abs_source}" "${trash_path}" "${reason}" "${module_name}" \
    "${now_iso}" "${size_bytes}" "${expires_iso}"; then
    added_key="${REPLY}"
  else
    mac_ops_log_warn "Copied but not indexed (reconcile will re-index it): ${trash_path}"
  fi
  _mac_ops_index_unlock

  # Re-verify the source right before removing it: anything written to it
  # since the copy would be lost. On any difference keep the source and take
  # the trashed copy back out.
  local now_sig=""
  if _mac_ops_tree_signature "${abs_source}"; then
    now_sig="${REPLY}"
  fi
  if [[ -z "${now_sig}" || "${now_sig}" != "${copy_sig}" ]]; then
    if _mac_ops_index_lock; then
      if [[ -n "${trash_path}" && "${trash_path}" == "${MAC_OPS_TRASH_DIR}/"* ]]; then
        rm -rf -- "${trash_path}" 2>/dev/null || true
      fi
      if [[ -n "${added_key}" ]]; then
        _mac_ops_index_load_locked
        _mac_ops_index_forget "${added_key}"
        mac_ops_index_write || true
      fi
      _mac_ops_index_unlock
    else
      mac_ops_log_error "Index lock unavailable: trashed copy left for reconcile: ${trash_path}"
    fi
    mac_ops_log_error "Source changed after it was copied (copy: '${copy_sig}', now: '${now_sig}' entries/bytes); source kept, trashed copy removed: ${abs_source}"
    return 1
  fi

  # The verified copy is in the trash and indexed: now remove the source
  if [[ -n "${abs_source}" && "${abs_source}" != "/" ]]; then
    rm -rf -- "${abs_source}" 2>/dev/null || true
  fi
  if [[ -e "${abs_source}" || -L "${abs_source}" ]]; then
    mac_ops_log_warn "Copied to trash but source could not be removed completely: ${abs_source}"
  fi

  mac_ops_log_info "Moved to trash: ${abs_source} (${size_bytes} bytes, reason: ${reason})"
  return 0
}

# -----------------------------------------------------------------------------
# ISO 8601 (UTC) <-> epoch. Result in REPLY (empty when it cannot be parsed).
# -----------------------------------------------------------------------------
_mac_ops_iso_to_epoch() {
  REPLY=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${1}" '+%s' 2>/dev/null) || REPLY=""
  [[ "${REPLY}" =~ ^[0-9]+$ ]] || REPLY=""
  return 0
}

_mac_ops_epoch_to_iso() {
  REPLY=$(date -u -r "${1}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || REPLY=""
  return 0
}

# -----------------------------------------------------------------------------
# Move a processed temp index file into the recovery directory. These files
# may hold the only record of when entries were really trashed: they are kept,
# never deleted.
# Usage: _mac_ops_trash_keep_recovery_file <temp_index_file>
# -----------------------------------------------------------------------------
_mac_ops_trash_keep_recovery_file() {
  local src="${1}"
  local base="${src##*/}"
  local dest="${MAC_OPS_TRASH_RECOVERY_DIR}/${base}"

  if _mac_ops_is_dry_run; then
    mac_ops_log_info "[DRY_RUN] Will move ${src} to ${MAC_OPS_TRASH_RECOVERY_DIR}/"
    return 0
  fi

  if ! mkdir -p "${MAC_OPS_TRASH_RECOVERY_DIR}" 2>/dev/null; then
    mac_ops_log_error "Cannot create ${MAC_OPS_TRASH_RECOVERY_DIR}; temp index file left in place: ${src}"
    return 1
  fi

  local n=0
  while [[ -e "${dest}" || -L "${dest}" ]]; do
    n=$((n + 1))
    dest="${MAC_OPS_TRASH_RECOVERY_DIR}/${base}.${n}"
  done

  if ! _mac_ops_trash_rename "${src}" "${dest}"; then
    mac_ops_log_error "Could not move temp index file to ${MAC_OPS_TRASH_RECOVERY_DIR} (left in place): ${src}"
    return 1
  fi
  mac_ops_log_info "Kept temp index file for recovery: ${dest}"
  return 0
}

# -----------------------------------------------------------------------------
# Newest change time (epoch) of a trash entry: its own ctime, or that of a
# directory nested up to 3 levels below it if newer. Informational only (it is
# recorded as "original_time" of a re-indexed entry, never used for expiry).
# Falls back to "now" when the entry cannot be examined. Result in REPLY.
# -----------------------------------------------------------------------------
_mac_ops_trash_entry_ctime() {
  setopt LOCAL_OPTIONS NO_PIPE_FAIL
  local entry="${1}"
  local own="" newest=""

  own=$(stat -f%c "${entry}" 2>/dev/null) || own=""
  if [[ ! "${own}" =~ ^[0-9]+$ ]]; then
    REPLY=$(date +%s)
    return 0
  fi

  if [[ -d "${entry}" && ! -L "${entry}" ]]; then
    newest=$(find "${entry}" -mindepth 1 -maxdepth 3 -type d -exec stat -f%c {} + 2>/dev/null | sort -n | tail -1) || newest=""
    if [[ "${newest}" =~ ^[0-9]+$ && ${newest} -gt ${own} ]]; then
      own="${newest}"
    fi
  fi

  REPLY="${own}"
  return 0
}

# -----------------------------------------------------------------------------
# Recover index entries from leftover temp index files (".index.json.tmp.*"
# older than one hour: an interrupted index write leaves one behind, and it
# may hold entries the index has since lost, with their real trashed times).
# The caller must hold the index lock and have the index loaded.
#
# An entry is taken over when the file is valid JSON, the entry is still on
# disk inside the trash and nothing in the index covers it (same path, a
# parent or a child of it). It keeps its recorded trashed time only if that
# leaves at least MAC_OPS_TRASH_RECOVERY_MIN_LEFT_HOURS (default 24) before it
# expires; otherwise it is stamped now and gets the full retention period.
#
# Sets _MAC_OPS_RECOVERY_FILES to the processed temp files (the caller moves
# them into the recovery directory once the index is written).
# Number of recovered entries in REPLY.
# -----------------------------------------------------------------------------
_mac_ops_trash_recover_tmp_locked() {
  setopt LOCAL_OPTIONS NULL_GLOB
  typeset -ga _MAC_OPS_RECOVERY_FILES
  _MAC_OPS_RECOVERY_FILES=()
  local recovered=0

  local -a tmp_files
  # Regular files not modified within the last 60 minutes, newest first (the
  # most recent recorded state of an entry wins)
  tmp_files=("${MAC_OPS_TRASH_DIR}"/.index.json.tmp.*(N.om^mm-60))
  if [[ ${#tmp_files[@]} -eq 0 ]]; then
    REPLY=0
    return 0
  fi

  local now_epoch
  now_epoch=$(date +%s)
  local retention_s=$(( MAC_OPS_TRASH_RETENTION_HOURS * 3600 ))
  local min_left_s=$(( ${MAC_OPS_TRASH_RECOVERY_MIN_LEFT_HOURS:-24} * 3600 ))
  local now_key_ts
  now_key_ts=$(date '+%Y%m%d%H%M%S')

  # Trash paths covered by the loaded index, and their parent directories
  local -A covered ancestors
  local key tp parent
  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    tp="${_MAC_OPS_IDX_TRASH[${key}]}"
    [[ -n "${tp}" ]] || continue
    covered[${tp}]=1
    parent="${tp%/*}"
    while [[ "${parent}" == "${MAC_OPS_TRASH_DIR}/"* && -z "${ancestors[${parent}]+_}" ]]; do
      ancestors[${parent}]=1
      parent="${parent%/*}"
    done
  done

  local -a r_keys
  local -A r_orig r_reason r_module r_time r_size r_trash
  local tmp_file rel first inside
  local f_key f_orig f_trash f_reason f_module f_time f_size
  local t_epoch e_epoch new_key new_time new_expire new_source note path_hash key_ts verb

  if _mac_ops_is_dry_run; then
    verb="[DRY_RUN] Will recover"
  else
    verb="Recovered"
  fi

  for tmp_file in "${tmp_files[@]}"; do
    _MAC_OPS_RECOVERY_FILES+=("${tmp_file}")

    if ! plutil -convert xml1 -o /dev/null -- "${tmp_file}" >/dev/null 2>&1; then
      mac_ops_log_info "Temp index file is not valid JSON, nothing recovered from it: ${tmp_file}"
      continue
    fi

    # Parse in a subshell into scratch arrays (the loaded index stays intact)
    r_keys=()
    r_orig=()
    r_trash=()
    r_reason=()
    r_module=()
    r_time=()
    r_size=()
    while IFS= read -r -d '' f_key && IFS= read -r -d '' f_orig \
      && IFS= read -r -d '' f_trash && IFS= read -r -d '' f_reason \
      && IFS= read -r -d '' f_module && IFS= read -r -d '' f_time \
      && IFS= read -r -d '' f_size; do
      r_keys+=("${f_key}")
      r_orig[${f_key}]="${f_orig}"
      r_trash[${f_key}]="${f_trash}"
      r_reason[${f_key}]="${f_reason}"
      r_module[${f_key}]="${f_module}"
      r_time[${f_key}]="${f_time}"
      r_size[${f_key}]="${f_size}"
    done < <(_mac_ops_index_dump_file "${tmp_file}")

    for key in "${r_keys[@]}"; do
      tp="${r_trash[${key}]}"
      [[ "${tp}" == "${MAC_OPS_TRASH_DIR}/"* ]] || continue
      [[ -e "${tp}" || -L "${tp}" ]] || continue

      # Never the bookkeeping files of the trash itself
      rel="${tp#"${MAC_OPS_TRASH_DIR}/"}"
      first="${rel%%/*}"
      case "${first}" in
        .index.json*|.index.lock*|.index.flock|.index-recovery|.staging)
          continue
          ;;
      esac

      # Already covered by the index (same path or a parent directory of an
      # indexed entry), or inside an indexed entry
      [[ -n "${covered[${tp}]+_}" || -n "${ancestors[${tp}]+_}" ]] && continue
      inside=false
      parent="${tp%/*}"
      while [[ "${parent}" == "${MAC_OPS_TRASH_DIR}/"* ]]; do
        if [[ -n "${covered[${parent}]+_}" ]]; then
          inside=true
          break
        fi
        parent="${parent%/*}"
      done
      [[ "${inside}" == true ]] && continue

      # Keep the recorded time only with at least min_left_s before expiry
      _mac_ops_iso_to_epoch "${r_time[${key}]}"
      t_epoch="${REPLY}"
      e_epoch=""
      [[ -n "${t_epoch}" ]] && e_epoch=$((t_epoch + retention_s))
      if [[ -n "${e_epoch}" && $((e_epoch - now_epoch)) -ge ${min_left_s} ]]; then
        new_time="${r_time[${key}]}"
        _mac_ops_epoch_to_iso "${e_epoch}"
        new_expire="${REPLY}"
        new_source="recovered"
        note="kept original time"
      else
        _mac_ops_epoch_to_iso "${now_epoch}"
        new_time="${REPLY}"
        _mac_ops_epoch_to_iso "$((now_epoch + retention_s))"
        new_expire="${REPLY}"
        new_source="reconcile"
        note="re-stamped now"
      fi

      new_key="${key}"
      if [[ -n "${_MAC_OPS_IDX_ORIG[${new_key}]+_}" || "${new_key}" != *_* ]]; then
        path_hash=$(print -n "${r_orig[${key}]}" | shasum -a 256 | cut -d' ' -f1)
        key_ts="${now_key_ts}"
        new_key="${path_hash}_${key_ts}"
        while [[ -n "${_MAC_OPS_IDX_ORIG[${new_key}]+_}" ]]; do
          key_ts=$((key_ts + 1))
          new_key="${path_hash}_${key_ts}"
        done
      fi

      _MAC_OPS_IDX_KEYS+=("${new_key}")
      _MAC_OPS_IDX_ORIG[${new_key}]="${r_orig[${key}]}"
      _MAC_OPS_IDX_TRASH[${new_key}]="${tp}"
      _MAC_OPS_IDX_REASON[${new_key}]="${r_reason[${key}]:-recovered-from-temp-index}"
      _MAC_OPS_IDX_MODULE[${new_key}]="${r_module[${key}]:-reconcile}"
      _MAC_OPS_IDX_TIME[${new_key}]="${new_time}"
      _MAC_OPS_IDX_SIZE[${new_key}]="${r_size[${key}]:-0}"
      _MAC_OPS_IDX_EXPIRE[${new_key}]="${new_expire}"
      _MAC_OPS_IDX_SOURCE[${new_key}]="${new_source}"
      _MAC_OPS_IDX_ORIGTIME[${new_key}]="${r_time[${key}]}"
      _MAC_OPS_RECONCILED_KEYS[${new_key}]=1

      covered[${tp}]=1
      parent="${tp%/*}"
      while [[ "${parent}" == "${MAC_OPS_TRASH_DIR}/"* && -z "${ancestors[${parent}]+_}" ]]; do
        ancestors[${parent}]=1
        parent="${parent%/*}"
      done

      recovered=$((recovered + 1))
      mac_ops_log_info "${verb} trash entry from ${tmp_file##*/}: ${tp} (size ${r_size[${key}]:-0} bytes, original time ${r_time[${key}]:-unknown}, expires ${new_expire}, ${note})"
    done
  done

  REPLY="${recovered}"
  return 0
}

# -----------------------------------------------------------------------------
# Reconcile the trash directory with the index. The caller must hold the index
# lock and have the index loaded (_mac_ops_index_load_locked).
#
# 1. Removes staging leftovers older than one hour (an interrupted verified
#    copy; its source was never removed).
# 2. Recovers entries recorded in leftover temp index files (see above) and
#    then moves those files into .index-recovery/ (never deletes them).
# 3. Re-indexes every trash entry that no index record refers to. The trash
#    mirrors original paths, so an "entry" is the shallowest path that is
#    neither an indexed trash path, nor a parent directory of one, nor inside
#    one, nor the mirror of a directory that still exists at its original
#    location. It is stamped with the CURRENT time, so it gets the full
#    retention period from the moment it is discovered; its change time is
#    recorded as "original_time" for information, and it is marked with
#    "source": "reconcile".
# Before step 3, records whose trash path no longer exists are dropped (and
# logged): nothing is left to purge or restore.
#
# Nothing in the trash is deleted here, and every key added here is listed in
# _MAC_OPS_RECONCILED_KEYS so the purge pass that ran this reconcile never
# deletes it. Dry-run: everything is computed and logged, nothing is written.
# Number of re-indexed + recovered entries in REPLY.
# -----------------------------------------------------------------------------
_mac_ops_trash_reconcile_locked() {
  setopt LOCAL_OPTIONS GLOB_DOTS NULL_GLOB
  local reindexed=0
  local recovered=0
  local dry=false
  if _mac_ops_is_dry_run; then
    dry=true
  fi
  _MAC_OPS_RECONCILED_KEYS=()

  # --- 1. Staging leftovers ---
  local stale_stage
  local -a stale_stages
  if [[ -d "${MAC_OPS_TRASH_STAGING_DIR}" ]]; then
    stale_stages=("${MAC_OPS_TRASH_STAGING_DIR}"/*(N^mm-60))
    for stale_stage in "${stale_stages[@]}"; do
      if [[ "${dry}" == true ]]; then
        mac_ops_log_info "[DRY_RUN] Will remove staging leftover: ${stale_stage}"
      else
        _mac_ops_trash_remove_staged "${stale_stage}"
      fi
    done
  fi

  # --- 2. Entries recorded in leftover temp index files ---
  _mac_ops_trash_recover_tmp_locked
  recovered="${REPLY}"

  # --- 3. Records whose trash path no longer exists ---
  # (deleted with an outer entry, removed by hand, ...): nothing is left to
  # purge or restore, so the record is dropped
  local key tp parent
  local -a dangling_keys
  dangling_keys=()
  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    tp="${_MAC_OPS_IDX_TRASH[${key}]}"
    [[ -n "${tp}" ]] && [[ -e "${tp}" || -L "${tp}" ]] && continue
    dangling_keys+=("${key}")
    if [[ "${dry}" == true ]]; then
      mac_ops_log_info "[DRY_RUN] Will drop index record whose trash path no longer exists: ${tp:-<empty>} (original ${_MAC_OPS_IDX_ORIG[${key}]})"
    else
      mac_ops_log_info "Dropped index record whose trash path no longer exists: ${tp:-<empty>} (original ${_MAC_OPS_IDX_ORIG[${key}]})"
    fi
  done
  local dropped=${#dangling_keys[@]}
  if [[ ${dropped} -gt 0 ]]; then
    _mac_ops_index_forget "${dangling_keys[@]}"
  fi

  # --- 4. Unindexed entries ---
  local -A indexed ancestors
  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    tp="${_MAC_OPS_IDX_TRASH[${key}]}"
    [[ "${tp}" == "${MAC_OPS_TRASH_DIR}/"* ]] || continue
    indexed[${tp}]=1
    parent="${tp%/*}"
    while [[ "${parent}" == "${MAC_OPS_TRASH_DIR}/"* ]]; do
      [[ -n "${ancestors[${parent}]+_}" ]] && break
      ancestors[${parent}]=1
      parent="${parent%/*}"
    done
  done

  local now_epoch
  now_epoch=$(date +%s)
  local now_iso expires_iso now_key_ts
  _mac_ops_epoch_to_iso "${now_epoch}"
  now_iso="${REPLY}"
  _mac_ops_epoch_to_iso "$((now_epoch + MAC_OPS_TRASH_RETENTION_HOURS * 3600))"
  expires_iso="${REPLY}"
  now_key_ts=$(date -r "${now_epoch}" '+%Y%m%d%H%M%S')

  local verb
  if [[ "${dry}" == true ]]; then
    verb="[DRY_RUN] Will re-index"
  else
    verb="Re-indexed"
  fi

  local -a queue children grandchildren
  queue=("${MAC_OPS_TRASH_DIR}")
  local dir child name
  local slashes=""
  local orig="" size="" orig_iso="" path_hash="" key_ts="" new_key=""

  while [[ ${#queue[@]} -gt 0 ]]; do
    dir="${queue[1]}"
    queue=("${queue[@]:1}")

    children=("${dir}"/*)
    for child in "${children[@]}"; do
      name="${child##*/}"

      # Bookkeeping files of the trash itself
      if [[ "${dir}" == "${MAC_OPS_TRASH_DIR}" ]]; then
        case "${name}" in
          .index.json|.index.json.tmp.*|.index.lock|.index.lock.*|.index.flock|.index-recovery|.staging|.DS_Store)
            continue
            ;;
        esac
      fi

      # Referenced by the index
      [[ -n "${indexed[${child}]+_}" ]] && continue

      if [[ -d "${child}" && ! -L "${child}" ]]; then
        # Parent directory of an indexed entry: look inside
        if [[ -n "${ancestors[${child}]+_}" ]]; then
          queue+=("${child}")
          continue
        fi

        # Mirror of a directory that still exists at its original location
        # (/Users, ~/Library/Caches, ...): it is path scaffolding created by
        # "mkdir -p", not something that was moved, so look inside. Limited
        # to the first levels to keep the number of entries bounded.
        orig="${child#"${MAC_OPS_TRASH_DIR}"}"
        slashes="${orig//[^\/]/}"
        if [[ ${#slashes} -le ${MAC_OPS_TRASH_RECONCILE_MAX_DEPTH:-6} && -d "${orig}" && ! -L "${orig}" ]]; then
          queue+=("${child}")
          continue
        fi
      fi

      # Empty directories are leftovers, removed by the purge step
      if [[ -d "${child}" && ! -L "${child}" ]]; then
        grandchildren=("${child}"/*)
        [[ ${#grandchildren[@]} -eq 0 ]] && continue
      fi

      # Unindexed entry: re-index it, stamped now
      _mac_ops_trash_entry_ctime "${child}"
      _mac_ops_epoch_to_iso "${REPLY}"
      orig_iso="${REPLY}"
      orig="${child#"${MAC_OPS_TRASH_DIR}"}"
      size=$(mac_ops_get_dir_size "${child}") || true
      [[ "${size}" =~ ^[0-9]+$ ]] || size=0
      path_hash=$(print -n "${orig}" | shasum -a 256 | cut -d' ' -f1)
      key_ts="${now_key_ts}"
      new_key="${path_hash}_${key_ts}"
      while [[ -n "${_MAC_OPS_IDX_ORIG[${new_key}]+_}" ]]; do
        key_ts=$((key_ts + 1))
        new_key="${path_hash}_${key_ts}"
      done

      _MAC_OPS_IDX_KEYS+=("${new_key}")
      _MAC_OPS_IDX_ORIG[${new_key}]="${orig}"
      _MAC_OPS_IDX_TRASH[${new_key}]="${child}"
      _MAC_OPS_IDX_REASON[${new_key}]="reconciled-unindexed"
      _MAC_OPS_IDX_MODULE[${new_key}]="reconcile"
      _MAC_OPS_IDX_TIME[${new_key}]="${now_iso}"
      _MAC_OPS_IDX_SIZE[${new_key}]="${size}"
      _MAC_OPS_IDX_EXPIRE[${new_key}]="${expires_iso}"
      _MAC_OPS_IDX_SOURCE[${new_key}]="reconcile"
      _MAC_OPS_IDX_ORIGTIME[${new_key}]="${orig_iso}"
      _MAC_OPS_RECONCILED_KEYS[${new_key}]=1
      indexed[${child}]=1
      reindexed=$((reindexed + 1))

      mac_ops_log_info "${verb} unindexed trash entry: ${child} (size ${size} bytes, original time ${orig_iso}, expires ${expires_iso})"
    done
  done

  # --- 5. Persist, then keep the processed temp files for recovery ---
  local changed=$((reindexed + recovered))
  local write_ok=true
  if [[ $((changed + dropped)) -gt 0 ]]; then
    if ! mac_ops_index_write; then
      write_ok=false
    fi
  fi
  if [[ ${changed} -gt 0 ]]; then
    mac_ops_log_warn "Reconcile: ${reindexed} unindexed and ${recovered} recovered trash entries indexed with a fresh retention period (not purged in this pass)"
  fi
  if [[ ${dropped} -gt 0 ]]; then
    mac_ops_log_warn "Reconcile: ${dropped} index records dropped (trash path no longer exists)"
  fi

  local tmp_file
  if [[ "${write_ok}" == true ]]; then
    for tmp_file in "${_MAC_OPS_RECOVERY_FILES[@]}"; do
      _mac_ops_trash_keep_recovery_file "${tmp_file}" || true
    done
  fi

  REPLY="${changed}"
  return 0
}

# -----------------------------------------------------------------------------
# Reconcile the trash directory with the index (see above). Deletes nothing;
# re-indexed entries expire through the normal purge after a full retention
# period from now.
# Usage: mac_ops_trash_reconcile
# -----------------------------------------------------------------------------
mac_ops_trash_reconcile() {
  if ! _mac_ops_index_lock; then
    mac_ops_log_error "Reconcile skipped (index lock unavailable)"
    return 1
  fi

  _mac_ops_index_load_locked
  _mac_ops_trash_reconcile_locked

  _mac_ops_index_unlock
  return 0
}

# -----------------------------------------------------------------------------
# Free space (KB) of the volume holding the trash, from df. Result in REPLY
# (empty if df fails).
# -----------------------------------------------------------------------------
_mac_ops_trash_volume_free_kb() {
  setopt LOCAL_OPTIONS NO_PIPE_FAIL
  REPLY=$(df -k "${MAC_OPS_TRASH_DIR}" 2>/dev/null | awk 'NR == 2 { print $4 }') || REPLY=""
  [[ "${REPLY}" =~ ^[0-9]+$ ]] || REPLY=""
  return 0
}

# -----------------------------------------------------------------------------
# Permanently delete expired items
# Reconciles the index with the disk first, then deletes entries whose
# expire_after is before the current time - except entries the reconcile of
# this same pass has just indexed. Runs under the index lock.
# Dry-run: logs what would be deleted, changes nothing.
# -----------------------------------------------------------------------------
mac_ops_trash_expire() {
  local now_epoch
  now_epoch=$(date +%s)
  local deleted_count=0
  local failed_count=0
  local purged_bytes=0
  local dry=false
  if _mac_ops_is_dry_run; then
    dry=true
  fi

  if ! _mac_ops_index_lock; then
    mac_ops_log_error "Purge skipped (index lock unavailable)"
    return 1
  fi

  _mac_ops_index_load_locked

  # Drop empty leftover directories, then pick up entries the index lost
  if [[ "${dry}" == true ]]; then
    mac_ops_log_info "[DRY_RUN] Will remove empty directories in ${MAC_OPS_TRASH_DIR}"
  else
    find "${MAC_OPS_TRASH_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  fi
  _mac_ops_trash_reconcile_locked

  _mac_ops_trash_volume_free_kb
  local free_before_kb="${REPLY}"

  # Collect keys to remove (cannot modify arrays during iteration)
  local remove_keys=()
  local key
  local expires_at=""
  local expires_epoch=""
  local trash_path=""
  local size_bytes=0

  # A trash path may be shared by several records (older versions reused the
  # path of an entry whose directory had disappeared) and an entry may hold
  # another indexed entry inside it (older versions nested a re-trashed child
  # into its parent's entry). A path is deleted only when EVERY record that
  # owns it has expired, and never while a live record sits underneath it.
  local -A path_keys path_live path_expire blocked_by
  local -a path_order
  local parent=""
  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    trash_path="${_MAC_OPS_IDX_TRASH[${key}]}"
    # (records without a trash path are dropped by the reconcile above)
    [[ -n "${trash_path}" ]] || continue
    if [[ -z "${path_keys[${trash_path}]+_}" ]]; then
      path_order+=("${trash_path}")
      path_keys[${trash_path}]=""
    fi
    path_keys[${trash_path}]+="${key} "

    expires_epoch=""
    expires_at="${_MAC_OPS_IDX_EXPIRE[${key}]}"
    # Found by this pass's reconcile: it gets its full retention period.
    # Convert ISO8601 (UTC) -> epoch. Without -u the "Z" time would be read as
    # local time and items would expire early/late by the UTC offset.
    if [[ -z "${_MAC_OPS_RECONCILED_KEYS[${key}]+_}" && -n "${expires_at}" ]]; then
      expires_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${expires_at}" '+%s' 2>/dev/null) || expires_epoch=""
    fi
    if [[ -z "${expires_epoch}" || ${now_epoch} -lt ${expires_epoch} ]]; then
      path_live[${trash_path}]=1
    elif [[ -z "${path_expire[${trash_path}]}" || "${expires_at}" > "${path_expire[${trash_path}]}" ]]; then
      path_expire[${trash_path}]="${expires_at}"
    fi
  done

  # Parent directories of every live path are blocked
  for trash_path in "${path_order[@]}"; do
    [[ -n "${path_live[${trash_path}]+_}" && -n "${trash_path}" ]] || continue
    parent="${trash_path%/*}"
    while [[ "${parent}" == "${MAC_OPS_TRASH_DIR}/"* ]]; do
      [[ -z "${blocked_by[${parent}]+_}" ]] && blocked_by[${parent}]="${trash_path}"
      parent="${parent%/*}"
    done
  done

  local -a path_key_list
  local verb_prefix=""
  [[ "${dry}" == true ]] && verb_prefix="[DRY_RUN] "
  for trash_path in "${path_order[@]}"; do
    [[ -n "${path_live[${trash_path}]+_}" ]] && continue
    path_key_list=(${=path_keys[${trash_path}]})
    expires_at="${path_expire[${trash_path}]}"
    size_bytes="${_MAC_OPS_IDX_SIZE[${path_key_list[1]}]:-0}"

    if [[ -n "${blocked_by[${trash_path}]+_}" ]]; then
      mac_ops_log_info "${verb_prefix}Expired trash entry postponed, it holds a live entry: ${trash_path} (live: ${blocked_by[${trash_path}]})"
      continue
    fi

    if [[ "${dry}" == true ]]; then
      mac_ops_log_info "[DRY_RUN] Will permanently delete: ${trash_path} (${size_bytes} bytes, expired ${expires_at}, ${#path_key_list[@]} records)"
      purged_bytes=$((purged_bytes + size_bytes))
      deleted_count=$((deleted_count + 1))
      continue
    fi

    # Permanently delete trash file (guard: must be inside MAC_OPS_TRASH_DIR)
    if [[ -n "${trash_path}" && "${trash_path}" == "${MAC_OPS_TRASH_DIR}/"* ]] \
      && [[ -e "${trash_path}" || -L "${trash_path}" ]]; then
      rm -rf -- "${trash_path}" 2>/dev/null || true
      if [[ -e "${trash_path}" || -L "${trash_path}" ]]; then
        # Keep the index records: dropping them would leave the item on disk
        # with nothing left to purge or list it
        failed_count=$((failed_count + 1))
        mac_ops_log_warn "Could not delete expired trash item (kept in index, will retry): ${trash_path}"
        continue
      fi
      purged_bytes=$((purged_bytes + size_bytes))
    fi

    remove_keys+=("${path_key_list[@]}")
    deleted_count=$((deleted_count + 1))
  done

  # Remove expired entries from index
  if [[ ${#remove_keys[@]} -gt 0 ]]; then
    _mac_ops_index_forget "${remove_keys[@]}"
    mac_ops_index_write || true
  fi

  # Clean up empty directories
  if [[ "${dry}" != true ]]; then
    find "${MAC_OPS_TRASH_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  fi

  _mac_ops_index_unlock

  local purged_mb=$((purged_bytes / 1048576))
  if [[ "${dry}" == true ]]; then
    mac_ops_log_info "[DRY_RUN] Expiration preview: ${deleted_count} items would be deleted (${purged_mb}MB by index size)"
    return 0
  fi

  # Report: the indexed size is a du figure taken at move time, not
  # necessarily what the volume gets back (APFS clones share blocks,
  # snapshots can pin them). The df delta is the measured change.
  _mac_ops_trash_volume_free_kb
  local free_after_kb="${REPLY}"
  local df_note="free space change unavailable"
  if [[ -n "${free_before_kb}" && -n "${free_after_kb}" ]]; then
    local delta_kb=$((free_after_kb - free_before_kb))
    if [[ ${delta_kb} -ge 0 ]]; then
      df_note="free space +$((delta_kb / 1024))MB by df"
    else
      df_note="free space -$(( (0 - delta_kb) / 1024 ))MB by df"
    fi
  fi

  mac_ops_log_info "Expiration completed: ${deleted_count} items deleted (${purged_mb}MB by index size, ${df_note}), ${failed_count} failed"
  return 0
}

# -----------------------------------------------------------------------------
# Restore from trash to original location (under the index lock)
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

  if ! _mac_ops_index_lock; then
    mac_ops_log_error "Restore skipped (index lock unavailable): ${original_path}"
    return 1
  fi

  _mac_ops_index_load_locked

  local found_key=""
  local latest_ts=0
  local key
  local key_ts=""

  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    # Match keys that start with the path hash
    if [[ "${key}" == "${path_hash}_"* ]]; then
      # Extract timestamp from key suffix
      key_ts="${key#${path_hash}_}"
      if [[ "${key_ts}" =~ ^[0-9]+$ && ${key_ts} -gt ${latest_ts} ]]; then
        latest_ts=${key_ts}
        found_key="${key}"
      fi
    fi
  done

  if [[ -z "${found_key}" ]]; then
    _mac_ops_index_unlock
    mac_ops_log_error "Cannot find item to restore: ${original_path}"
    return 1
  fi

  local trash_path="${_MAC_OPS_IDX_TRASH[${found_key}]}"

  if [[ -z "${trash_path}" ]] || [[ ! -e "${trash_path}" && ! -L "${trash_path}" ]]; then
    mac_ops_log_error "Trash file does not exist: ${trash_path}"
    # Remove dangling entry
    _mac_ops_index_forget "${found_key}"
    mac_ops_index_write || true
    _mac_ops_index_unlock
    return 1
  fi

  # Abort if file already exists at original location
  if [[ -e "${original_path}" || -L "${original_path}" ]]; then
    _mac_ops_index_unlock
    mac_ops_log_error "File already exists at original location: ${original_path}"
    return 1
  fi

  if _mac_ops_is_dry_run; then
    _mac_ops_index_unlock
    mac_ops_log_info "[DRY_RUN] Will restore: ${trash_path} -> ${original_path}"
    return 0
  fi

  # Create parent directory of original location
  local restore_parent="${original_path:h}"
  if [[ ! -d "${restore_parent}" ]]; then
    mkdir -p "${restore_parent}" 2>/dev/null || true
  fi

  # Execute restore
  if ! mv "${trash_path}" "${original_path}" 2>/dev/null; then
    _mac_ops_index_unlock
    mac_ops_log_error "Restore failed: ${trash_path} -> ${original_path}"
    return 1
  fi

  # Remove entry from index
  _mac_ops_index_forget "${found_key}"
  mac_ops_index_write || true

  # Clean up empty directories
  find "${MAC_OPS_TRASH_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true

  _mac_ops_index_unlock
  mac_ops_log_info "Restore completed: ${original_path}"
  return 0
}
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
      exp_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${expires}" '+%s' 2>/dev/null) || exp_epoch=""
      if [[ -n "${exp_epoch}" && ${exp_epoch} -lt ${earliest_epoch} ]]; then
        earliest_epoch=${exp_epoch}
        earliest_expires="${expires}"
      fi
    fi
  done

  local human_total
  human_total=$(_mac_ops_human_size "${total_bytes}")

  # What the trash really occupies on disk (the index total is the sum of du
  # figures taken at move time and misses anything the index does not know)
  local on_disk_bytes
  on_disk_bytes=$(mac_ops_get_dir_size "${MAC_OPS_TRASH_DIR}") || true
  [[ "${on_disk_bytes}" =~ ^[0-9]+$ ]] || on_disk_bytes=0
  local human_on_disk
  human_on_disk=$(_mac_ops_human_size "${on_disk_bytes}")

  print "=== mac-ops Trash Status ==="
  print "Total items: ${item_count}"
  print "Total size:  ${human_total} (indexed; moved to trash, pending purge - not reclaimed yet)"
  print "On disk:     ${human_on_disk} (du of ${MAC_OPS_TRASH_DIR})"
  if [[ ${on_disk_bytes} -gt $((total_bytes + total_bytes / 10 + 1048576)) ]]; then
    print "             Trash holds more than the index lists; 'mac-ops purge' re-indexes"
    print "             unindexed items with a full ${MAC_OPS_TRASH_RETENTION_HOURS}h retention from that moment"
    print "             (they are never deleted in the pass that finds them)."
  fi
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
