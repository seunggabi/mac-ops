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

# Staging area for verified copies (never scanned by reconcile)
MAC_OPS_TRASH_STAGING_DIR="${MAC_OPS_TRASH_DIR}/.staging"

# Seconds to wait for the index lock before giving up (the caller then fails
# safe: nothing is moved or rewritten without the lock)
MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS=${MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS:-120}

# Re-entrancy depth of the index lock inside the current process
typeset -gi _MAC_OPS_INDEX_LOCK_DEPTH=0

# zsh/system: real PID of a subshell ($$ stays the parent PID in subshells)
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
# Acquire a mutex lock on the JSON index file
# Usage: if ! _mac_ops_index_lock; then <fail safe>; fi
# Returns 1 on timeout. Callers must NOT touch the index or move files into
# the trash without the lock: unlocked read-modify-write cycles of parallel
# modules overwrite each other and silently drop entries.
# The owner PID is stored inside the lock directory, so a lock is only broken
# when its owner is dead (never just because it has been held for a while).
# -----------------------------------------------------------------------------
_mac_ops_index_lock() {
  if [[ ${_MAC_OPS_INDEX_LOCK_DEPTH} -gt 0 ]]; then
    _MAC_OPS_INDEX_LOCK_DEPTH=$((_MAC_OPS_INDEX_LOCK_DEPTH + 1))
    return 0
  fi

  mkdir -p "${MAC_OPS_TRASH_DIR}" 2>/dev/null || true

  local max_tries=$(( MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS * 10 ))
  local tries=0
  local owner_pid=""
  local lock_mtime=""
  local stale=false
  local stale_dir=""

  _mac_ops_self_pid
  local self_pid="${REPLY}"

  while ! mkdir "${MAC_OPS_INDEX_LOCK_DIR}" 2>/dev/null; do
    stale=false
    owner_pid=""
    if [[ -f "${MAC_OPS_INDEX_LOCK_DIR}/pid" ]]; then
      owner_pid=$(cat "${MAC_OPS_INDEX_LOCK_DIR}/pid" 2>/dev/null) || owner_pid=""
    fi

    if [[ "${owner_pid}" =~ ^[0-9]+$ ]]; then
      # Owner recorded: stale only if that process is gone
      if ! kill -0 "${owner_pid}" 2>/dev/null; then
        stale=true
      fi
    else
      # No owner recorded (crash between mkdir and pid write, or a lock left
      # by an older version): stale once it is older than 60 seconds
      lock_mtime=$(stat -f%m "${MAC_OPS_INDEX_LOCK_DIR}" 2>/dev/null) || lock_mtime=""
      if [[ "${lock_mtime}" =~ ^[0-9]+$ && $(( $(date +%s) - lock_mtime )) -gt 60 ]]; then
        stale=true
      fi
    fi

    if [[ "${stale}" == true ]]; then
      # Take the stale lock away with a rename so only one waiter wins
      stale_dir="${MAC_OPS_INDEX_LOCK_DIR}.stale.${self_pid}"
      if _mac_ops_trash_rename "${MAC_OPS_INDEX_LOCK_DIR}" "${stale_dir}"; then
        rm -f "${stale_dir}/pid" 2>/dev/null || true
        rmdir "${stale_dir}" 2>/dev/null || true
        mac_ops_log_warn "Removed stale index lock (owner: ${owner_pid:-unknown})"
      fi
      continue
    fi

    tries=$((tries + 1))
    if [[ ${tries} -gt ${max_tries} ]]; then
      mac_ops_log_error "Index lock timeout after ${MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS}s (owner: ${owner_pid:-unknown})"
      return 1
    fi
    sleep 0.1
  done

  print -r -- "${self_pid}" > "${MAC_OPS_INDEX_LOCK_DIR}/pid" 2>/dev/null || true
  _MAC_OPS_INDEX_LOCK_DEPTH=1
  return 0
}

# -----------------------------------------------------------------------------
# Release the mutex lock on the JSON index file
# Only releases a lock this process actually holds.
# Usage: _mac_ops_index_unlock
# -----------------------------------------------------------------------------
_mac_ops_index_unlock() {
  if [[ ${_MAC_OPS_INDEX_LOCK_DEPTH} -le 0 ]]; then
    return 0
  fi

  _MAC_OPS_INDEX_LOCK_DEPTH=$((_MAC_OPS_INDEX_LOCK_DEPTH - 1))
  if [[ ${_MAC_OPS_INDEX_LOCK_DEPTH} -gt 0 ]]; then
    return 0
  fi

  rm -f "${MAC_OPS_INDEX_LOCK_DIR}/pid" 2>/dev/null || true
  rmdir "${MAC_OPS_INDEX_LOCK_DIR}" 2>/dev/null || true
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
  return 0
}

# -----------------------------------------------------------------------------
# Read the JSON index into global associative arrays
# Creates a default empty index if the file does not exist
# Migrates old .plist metadata on first access
# -----------------------------------------------------------------------------
mac_ops_index_read() {
  _mac_ops_index_reset

  # Migrate old plist metadata if present (loads, rewrites the index file)
  _mac_ops_migrate_plist_to_index
  _mac_ops_index_reset

  # Create default if missing
  if [[ ! -f "${MAC_OPS_INDEX_FILE}" ]]; then
    mac_ops_index_write
    return 0
  fi

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
#          <module> <timestamp> <size_bytes> <expire_after>
# -----------------------------------------------------------------------------
_mac_ops_index_add_locked() {
  local key="${1}"

  mac_ops_index_read

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

  if ! mac_ops_index_write; then
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

  mac_ops_index_read
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
# =============================================================================
_mac_ops_migrate_plist_to_index() {
  # Skip if metadata directory does not exist or has no plist files
  [[ ! -d "${MAC_OPS_META_DIR}" ]] && return 0

  local plist_files
  # shellcheck disable=SC1036
  plist_files=("${MAC_OPS_META_DIR}"/*.plist(N))
  [[ ${#plist_files} -eq 0 ]] && return 0

  # Load existing index if present (without triggering migration again)
  _mac_ops_index_parse_file "${MAC_OPS_INDEX_FILE}"

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

  REPLY="${staged}"
  return 0
}

# -----------------------------------------------------------------------------
# Pick a trash path that does not exist yet. Result in REPLY.
# The caller must hold the index lock so the name stays free until the rename
# (renaming onto an existing directory would nest the entry inside it).
# Usage: _mac_ops_trash_free_path <wanted_trash_path>
# -----------------------------------------------------------------------------
_mac_ops_trash_free_path() {
  local wanted="${1}"
  local candidate="${wanted}"

  if [[ -e "${candidate}" || -L "${candidate}" ]]; then
    local ts_suffix
    ts_suffix=$(date '+%Y%m%d_%H%M%S')
    candidate="${wanted}.${ts_suffix}"
    local n=0
    while [[ -e "${candidate}" || -L "${candidate}" ]]; do
      n=$((n + 1))
      candidate="${wanted}.${ts_suffix}_${n}"
    done
  fi

  REPLY="${candidate}"
  return 0
}

# =============================================================================
# Open-file detection
# =============================================================================

# -----------------------------------------------------------------------------
# Path of a cached "lsof -Fn" name list. Result in REPLY.
# One list is built and shared by every module of a run (lsof +D per directory
# is far too slow); it is rebuilt when older than
# MAC_OPS_OPEN_FILES_TTL_SECONDS (default 60).
# Returns 1 when no list can be produced.
# -----------------------------------------------------------------------------
_mac_ops_open_files_list() {
  local list_dir="${MAC_OPS_HOME}/.tmp"
  local list_file="${list_dir}/open-files.list"
  local ttl="${MAC_OPS_OPEN_FILES_TTL_SECONDS:-60}"
  local now mtime
  REPLY=""

  now=$(date +%s)
  if [[ -s "${list_file}" ]]; then
    mtime=$(stat -f%m "${list_file}" 2>/dev/null) || mtime=0
    if [[ "${mtime}" =~ ^[0-9]+$ && $((now - mtime)) -lt ${ttl} ]]; then
      REPLY="${list_file}"
      return 0
    fi
  fi

  if ! command -v lsof >/dev/null 2>&1; then
    return 1
  fi
  if ! mkdir -p "${list_dir}" 2>/dev/null; then
    return 1
  fi

  local tmp_list=""
  tmp_list=$(mktemp "${list_file}.XXXXXX" 2>/dev/null) || tmp_list=""
  if [[ -z "${tmp_list}" ]]; then
    return 1
  fi

  # lsof exits non-zero on harmless warnings; keep whatever it printed
  { lsof -nP -Fn 2>/dev/null || true; } | { grep '^n/' || true; } > "${tmp_list}" 2>/dev/null || true

  if [[ ! -s "${tmp_list}" ]] || ! mv -f "${tmp_list}" "${list_file}" 2>/dev/null; then
    rm -f "${tmp_list}" 2>/dev/null || true
    return 1
  fi

  REPLY="${list_file}"
  return 0
}

# -----------------------------------------------------------------------------
# Return 0 if a running process has the directory, or a file inside it, open.
# Returns 1 when nothing is open or when open files cannot be determined.
# Usage: _mac_ops_dir_has_open_files <directory>
# -----------------------------------------------------------------------------
_mac_ops_dir_has_open_files() {
  local dir_path="${1}"

  if ! _mac_ops_open_files_list; then
    mac_ops_log_debug "Open-file list unavailable, skipping in-use check: ${dir_path}"
    return 1
  fi
  local list_file="${REPLY}"

  # lsof prints resolved paths (/private/var/..., not /var/...)
  local real_path="${dir_path:A}"

  if MAC_OPS_NEEDLE="n${real_path}" LC_ALL=C awk '
      BEGIN { p = ENVIRON["MAC_OPS_NEEDLE"]; q = p "/" }
      $0 == p || index($0, q) == 1 { found = 1; exit }
      END { exit found ? 0 : 1 }
    ' "${list_file}" 2>/dev/null; then
    return 0
  fi
  return 1
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
# - A directory that a running process has files open in is not moved
#   (set MAC_OPS_TRASH_SKIP_OPEN_DIRS=false to disable).
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

  # Refuse directories that are in use by a running process
  if [[ "${MAC_OPS_TRASH_SKIP_OPEN_DIRS:-true}" == "true" && -d "${abs_source}" && ! -L "${abs_source}" ]]; then
    if _mac_ops_dir_has_open_files "${abs_source}"; then
      mac_ops_log_warn "Not moved, a running process has files open in: ${abs_source}"
      return 1
    fi
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

  if ! mkdir -p "${trash_parent}" 2>/dev/null; then
    _mac_ops_index_unlock
    mac_ops_log_error "Failed to create trash directory: ${trash_parent}"
    return 1
  fi

  # Add timestamp suffix if an entry already exists at the same path
  _mac_ops_trash_free_path "${wanted_path}"
  trash_path="${REPLY}"

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

  if ! _mac_ops_index_lock; then
    _mac_ops_trash_remove_staged "${stage_dir}"
    mac_ops_log_error "Not moved (index lock unavailable), source left untouched: ${abs_source}"
    return 1
  fi

  _mac_ops_trash_free_path "${wanted_path}"
  trash_path="${REPLY}"

  if ! _mac_ops_trash_rename "${staged}" "${trash_path}"; then
    _mac_ops_trash_remove_staged "${stage_dir}"
    _mac_ops_index_unlock
    mac_ops_log_error "Failed to move file, source left untouched: ${abs_source} -> ${trash_path}"
    return 1
  fi
  _mac_ops_trash_remove_staged "${stage_dir}"

  if ! _mac_ops_index_add_locked "${entry_key}" \
    "${abs_source}" "${trash_path}" "${reason}" "${module_name}" \
    "${now_iso}" "${size_bytes}" "${expires_iso}"; then
    mac_ops_log_warn "Copied but not indexed (reconcile will re-index it): ${trash_path}"
  fi
  _mac_ops_index_unlock

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
# Newest change time (epoch) of a trash entry: its own ctime, or that of a
# directory nested up to 3 levels below it if newer (an unindexed entry can be
# a container whose own ctime predates what was last moved into it).
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
# Reconcile the trash directory with the index. The caller must hold the index
# lock and have the index loaded (mac_ops_index_read).
#
# 1. Removes stale temp index files and staging leftovers (older than 1 hour).
# 2. Re-indexes every trash entry that no index record refers to. The trash
#    mirrors original paths, so an "entry" is the shallowest path that is
#    neither an indexed trash path, nor a parent directory of one, nor inside
#    one, nor the mirror of a directory that still exists at its original
#    location. Its trashed time is taken from its change time, so it expires
#    after the normal retention period instead of staying on disk forever.
#    Nothing is deleted here.
#
# Number of re-indexed entries in REPLY.
# -----------------------------------------------------------------------------
_mac_ops_trash_reconcile_locked() {
  setopt LOCAL_OPTIONS GLOB_DOTS NULL_GLOB
  local reindexed=0

  # --- 1. Stale temp files (an interrupted index write leaves one behind) ---
  find "${MAC_OPS_TRASH_DIR}" -mindepth 1 -maxdepth 1 -type f -name '.index.json.tmp.*' -mmin +60 -delete 2>/dev/null || true
  local stale_stage
  if [[ -d "${MAC_OPS_TRASH_STAGING_DIR}" ]]; then
    find "${MAC_OPS_TRASH_STAGING_DIR}" -mindepth 1 -maxdepth 1 -mmin +60 -print 2>/dev/null | while IFS= read -r stale_stage; do
      _mac_ops_trash_remove_staged "${stale_stage}"
    done || true
  fi

  # --- 2. Unindexed entries ---
  local -A indexed ancestors
  local key tp parent
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

  local -a queue children grandchildren
  queue=("${MAC_OPS_TRASH_DIR}")
  local dir child name
  local slashes=""
  local ctime="" orig="" size="" moved_iso="" expires_iso="" path_hash="" key_ts="" new_key=""

  while [[ ${#queue[@]} -gt 0 ]]; do
    dir="${queue[1]}"
    queue=("${queue[@]:1}")

    children=("${dir}"/*)
    for child in "${children[@]}"; do
      name="${child##*/}"

      # Bookkeeping files of the trash itself
      if [[ "${dir}" == "${MAC_OPS_TRASH_DIR}" ]]; then
        case "${name}" in
          .index.json|.index.json.tmp.*|.index.lock|.index.lock.stale.*|.staging|.DS_Store)
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

      # Unindexed entry: re-index it with its own change time
      _mac_ops_trash_entry_ctime "${child}"
      ctime="${REPLY}"
      orig="${child#"${MAC_OPS_TRASH_DIR}"}"
      size=$(mac_ops_get_dir_size "${child}") || true
      [[ "${size}" =~ ^[0-9]+$ ]] || size=0
      moved_iso=$(date -u -r "${ctime}" '+%Y-%m-%dT%H:%M:%SZ')
      expires_iso=$(date -u -r "$((ctime + MAC_OPS_TRASH_RETENTION_HOURS * 3600))" '+%Y-%m-%dT%H:%M:%SZ')
      path_hash=$(print -n "${orig}" | shasum -a 256 | cut -d' ' -f1)
      key_ts=$(date -r "${ctime}" '+%Y%m%d%H%M%S')
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
      _MAC_OPS_IDX_TIME[${new_key}]="${moved_iso}"
      _MAC_OPS_IDX_SIZE[${new_key}]="${size}"
      _MAC_OPS_IDX_EXPIRE[${new_key}]="${expires_iso}"
      indexed[${child}]=1
      reindexed=$((reindexed + 1))

      mac_ops_log_info "Re-indexed unindexed trash entry: ${child} (trashed ${moved_iso}, expires ${expires_iso})"
    done
  done

  if [[ ${reindexed} -gt 0 ]]; then
    mac_ops_index_write || true
    mac_ops_log_warn "Reconcile: ${reindexed} trash entries were on disk but missing from the index"
  fi

  REPLY="${reindexed}"
  return 0
}

# -----------------------------------------------------------------------------
# Reconcile the trash directory with the index (see above). Deletes nothing
# but stale temp files; re-indexed entries expire through the normal purge.
# Usage: mac_ops_trash_reconcile
# -----------------------------------------------------------------------------
mac_ops_trash_reconcile() {
  if ! _mac_ops_index_lock; then
    mac_ops_log_error "Reconcile skipped (index lock unavailable)"
    return 1
  fi

  mac_ops_index_read
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
# Reconciles the index with the disk first, then processes entries whose
# expire_after is before the current time. Runs under the index lock.
# -----------------------------------------------------------------------------
mac_ops_trash_expire() {
  local now_epoch
  now_epoch=$(date +%s)
  local deleted_count=0
  local failed_count=0
  local purged_bytes=0

  if ! _mac_ops_index_lock; then
    mac_ops_log_error "Purge skipped (index lock unavailable)"
    return 1
  fi

  mac_ops_index_read

  # Drop empty leftover directories, then pick up entries the index lost
  find "${MAC_OPS_TRASH_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
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

  for key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    expires_at="${_MAC_OPS_IDX_EXPIRE[${key}]}"
    [[ -z "${expires_at}" ]] && continue

    # Convert ISO8601 (UTC) -> epoch. Without -u the "Z" time would be read as
    # local time and items would expire early/late by the UTC offset.
    expires_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${expires_at}" '+%s' 2>/dev/null) || expires_epoch=""
    [[ -z "${expires_epoch}" ]] && continue

    # Check if expired
    if [[ ${now_epoch} -ge ${expires_epoch} ]]; then
      trash_path="${_MAC_OPS_IDX_TRASH[${key}]}"
      size_bytes="${_MAC_OPS_IDX_SIZE[${key}]:-0}"

      # Permanently delete trash file (guard: must be inside MAC_OPS_TRASH_DIR)
      if [[ -n "${trash_path}" && "${trash_path}" == "${MAC_OPS_TRASH_DIR}/"* ]] \
        && [[ -e "${trash_path}" || -L "${trash_path}" ]]; then
        rm -rf -- "${trash_path}" 2>/dev/null || true
        if [[ -e "${trash_path}" || -L "${trash_path}" ]]; then
          # Keep the index record: dropping it would leave the item on disk
          # with nothing left to purge or list it
          failed_count=$((failed_count + 1))
          mac_ops_log_warn "Could not delete expired trash item (kept in index, will retry): ${trash_path}"
          continue
        fi
        purged_bytes=$((purged_bytes + size_bytes))
      fi

      remove_keys+=("${key}")
      deleted_count=$((deleted_count + 1))
    fi
  done

  # Remove expired entries from index
  if [[ ${#remove_keys[@]} -gt 0 ]]; then
    _mac_ops_index_forget "${remove_keys[@]}"
    mac_ops_index_write || true
  fi

  # Clean up empty directories
  find "${MAC_OPS_TRASH_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true

  _mac_ops_index_unlock

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

  local purged_mb=$((purged_bytes / 1048576))
  mac_ops_log_info "Expiration completed: ${deleted_count} items deleted (${purged_mb}MB by index size, ${df_note}), ${failed_count} failed"
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
  find "${MAC_OPS_TRASH_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true

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
    print "             unindexed items so they expire after the retention period."
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
