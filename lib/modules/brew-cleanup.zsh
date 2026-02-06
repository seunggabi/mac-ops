# =============================================================================
# mac-ops: Homebrew cleanup module
# Clean brew cache and outdated formulas
# =============================================================================

# -----------------------------------------------------------------------------
# Homebrew cache and outdated package cleanup
# Usage: mac_ops_brew_cleanup
# -----------------------------------------------------------------------------
mac_ops_brew_cleanup() {
  # Check if brew command exists
  if ! command -v brew &>/dev/null; then
    mac_ops_log_info "Homebrew is not installed. Skipping."
    return 0
  fi

  mac_ops_log_info "Starting Homebrew cleanup..."

  local cache_dir
  cache_dir=$(brew --cache 2>/dev/null)

  if [[ -z "${cache_dir}" || ! -d "${cache_dir}" ]]; then
    mac_ops_log_warn "Cannot find Homebrew cache directory."
    return 1
  fi

  # Calculate cache directory size
  local cache_size
  cache_size=$(mac_ops_get_dir_size "${cache_dir}")
  local cache_mb=$((cache_size / 1048576))

  # DRY_RUN mode
  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will clean Homebrew cache: ${cache_dir} ($(mac_ops_format_bytes ${cache_size}))"

    # Check outdated formula list
    local cleanup_preview
    cleanup_preview=$(brew cleanup --dry-run 2>&1)
    if [[ -n "${cleanup_preview}" ]]; then
      mac_ops_log_info "[DRY_RUN] Will execute brew cleanup:"
      echo "${cleanup_preview}" | head -20
    fi

    return 0
  fi

  # Record size before actual cleanup
  local before_size
  before_size=$(mac_ops_get_dir_size "${cache_dir}")

  # Execute brew cleanup (clean items older than 7 days)
  mac_ops_log_info "Running brew cleanup (--prune=7)..."

  local cleanup_output
  cleanup_output=$(brew cleanup --prune=7 2>&1)
  local cleanup_status=$?

  if [[ ${cleanup_status} -ne 0 ]]; then
    mac_ops_log_error "brew cleanup failed: ${cleanup_output}"
    return 1
  fi

  # Calculate size after cleanup
  local after_size
  after_size=$(mac_ops_get_dir_size "${cache_dir}")

  local freed_bytes=$((before_size - after_size))

  # Prevent negative values (new cache may be created during cleanup)
  if [[ ${freed_bytes} -lt 0 ]]; then
    freed_bytes=0
  fi

  # Update global counter
  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + freed_bytes))

  # Estimate cleaned file count (try to extract from brew cleanup output)
  local cleaned_count
  cleaned_count=$(echo "${cleanup_output}" | grep -c "Removing:" || echo 0)
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + cleaned_count))

  local freed_mb=$((freed_bytes / 1048576))
  mac_ops_log_info "Homebrew cleanup completed: ${cleaned_count} items, $(mac_ops_format_bytes ${freed_bytes}) freed"

  # Output cleanup result summary
  if [[ -n "${cleanup_output}" ]]; then
    mac_ops_log_debug "brew cleanup output: ${cleanup_output}"
  fi

  return 0
}
