# =============================================================================
# mac-ops: User ignore rules loader
# Reads ~/.mac-ops/ignore and populates rule arrays for bundle IDs, processes, and paths.
#
# File format (~/.mac-ops/ignore):
#   # Comments start with #
#   [bundle]    Bundle ID patterns for orphan-app-cleanup
#   [process]   Process name patterns for zombie-killer, orphan-killer
#   [path]      Path patterns for all file-based cleanups
#
# Pattern syntax:
#   - Exact match:       com.mycompany.MyApp
#   - Prefix wildcard:   com.mycompany.*
#   - Glob wildcard:     MyHelper*
#   - Path with glob:    ~/work/project/**
# =============================================================================

# --- Global ignore rule arrays (populated by mac_ops_ignore_load) ---
typeset -ga _MAC_OPS_IGNORE_BUNDLES
typeset -ga _MAC_OPS_IGNORE_PROCESSES
typeset -ga _MAC_OPS_IGNORE_PATHS
_MAC_OPS_IGNORE_BUNDLES=()
_MAC_OPS_IGNORE_PROCESSES=()
_MAC_OPS_IGNORE_PATHS=()

# -----------------------------------------------------------------------------
# Load ignore rules from ~/.mac-ops/ignore
# Parses [bundle], [process], [path] sections into global arrays.
# Safe to call multiple times (resets on each call).
# Usage: mac_ops_ignore_load
# -----------------------------------------------------------------------------
mac_ops_ignore_load() {
  local ignore_file="${MAC_OPS_HOME}/ignore"

  _MAC_OPS_IGNORE_BUNDLES=()
  _MAC_OPS_IGNORE_PROCESSES=()
  _MAC_OPS_IGNORE_PATHS=()

  if [[ ! -f "${ignore_file}" ]]; then
    mac_ops_log_debug "No ignore file: ${ignore_file}"
    return 0
  fi

  local current_section=""
  local line

  while IFS= read -r line; do
    # Strip inline comments
    line="${line%%\#*}"

    # Trim leading/trailing whitespace
    line="${line##[[:space:]]#}"
    line="${line%%[[:space:]]#}"

    # Skip empty lines
    [[ -z "${line}" ]] && continue

    # Section header: [bundle], [process], [path]
    if [[ "${line}" == \[*\] ]]; then
      current_section="${line:1:-1}"
      continue
    fi

    # Expand ~ to $HOME in path patterns
    local expanded="${line/#\~/${HOME}}"

    case "${current_section}" in
      bundle)   _MAC_OPS_IGNORE_BUNDLES+=("${expanded}")   ;;
      process)  _MAC_OPS_IGNORE_PROCESSES+=("${expanded}") ;;
      path)     _MAC_OPS_IGNORE_PATHS+=("${expanded}")     ;;
      *)
        mac_ops_log_debug "Ignore file: unknown section '${current_section}', skipping: ${line}"
        ;;
    esac
  done < "${ignore_file}"

  mac_ops_log_debug "Ignore rules loaded — bundle: ${#_MAC_OPS_IGNORE_BUNDLES[@]}, process: ${#_MAC_OPS_IGNORE_PROCESSES[@]}, path: ${#_MAC_OPS_IGNORE_PATHS[@]}"
}

# -----------------------------------------------------------------------------
# Check if a bundle ID should be ignored by user rules
# Returns 0 (match = ignore), 1 (no match = proceed)
# Supports exact match and glob patterns (com.mycompany.*, MyApp*)
# Usage: mac_ops_ignore_check_bundle <bundle_id>
# -----------------------------------------------------------------------------
mac_ops_ignore_check_bundle() {
  local name="${1}"
  local pattern
  for pattern in "${_MAC_OPS_IGNORE_BUNDLES[@]}"; do
    # ${~pattern} enables glob expansion in the pattern (zsh-specific)
    # shellcheck disable=SC2053,SC2296
    if [[ "${name}" == ${~pattern} ]]; then
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# Check if a process name should be ignored by user rules
# Returns 0 (match = ignore), 1 (no match = proceed)
# Supports exact match and glob patterns (MyDaemon, MyHelper*)
# Usage: mac_ops_ignore_check_process <process_name>
# -----------------------------------------------------------------------------
mac_ops_ignore_check_process() {
  local name="${1}"
  local pattern
  for pattern in "${_MAC_OPS_IGNORE_PROCESSES[@]}"; do
    # shellcheck disable=SC2053,SC2296
    if [[ "${name}" == ${~pattern} ]]; then
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# Check if a filesystem path should be ignored by user rules
# Returns 0 (match = ignore), 1 (no match = proceed)
# Supports exact path, prefix (~/work/**), and glob patterns
# Usage: mac_ops_ignore_check_path <absolute_path>
# -----------------------------------------------------------------------------
mac_ops_ignore_check_path() {
  local target="${1}"
  local pattern
  for pattern in "${_MAC_OPS_IGNORE_PATHS[@]}"; do
    # Exact or glob match (${~pattern} is zsh-specific glob expansion)
    # shellcheck disable=SC2053,SC2296
    if [[ "${target}" == ${~pattern} ]]; then
      return 0
    fi
    # Prefix directory match: if pattern is /foo/bar, also protect /foo/bar/child
    local base="${pattern%/}"
    if [[ "${target}" == "${base}/"* ]]; then
      return 0
    fi
  done
  return 1
}
