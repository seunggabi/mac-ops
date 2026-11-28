# =============================================================================
# mac-ops: Homebrew cleanup module
# Clean brew cache and outdated formulas
# =============================================================================

# zsh-only nested expansions and modifiers; false positives in bash mode
# shellcheck disable=SC2296,SC2299

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

  # Another brew process is using the cache (install/upgrade in progress)
  if _mac_ops_fc_manager_running "brew"; then
    mac_ops_log_debug "Protected, skipped (brew-cleanup): Homebrew cache (reason: brew is running)"
    return 0
  fi

  # brew cleanup removes old kegs; a process started before an upgrade can
  # still be executing from one (a long-lived node or python)
  local keg_holders="" line=""
  keg_holders=$(_mac_ops_brew_old_kegs_in_use)
  if [[ $? -ne 0 ]]; then
    mac_ops_log_warn "Homebrew cleanup skipped this run: cannot list running processes (ps failed)"
    return 0
  fi
  if [[ -n "${keg_holders}" ]]; then
    mac_ops_log_warn "Homebrew cleanup skipped this run: running processes still use old kegs"
    while IFS= read -r line; do
      [[ -n "${line}" ]] && mac_ops_log_warn "  ${line}"
    done <<< "${keg_holders}"
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
  cleaned_count=$(echo "${cleanup_output}" | grep -c "Removing:" || true)
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + cleaned_count))

  local freed_mb=$((freed_bytes / 1048576))
  mac_ops_log_info "Homebrew cleanup completed: ${cleaned_count} items, $(mac_ops_format_bytes ${freed_bytes}) freed"

  # Output cleanup result summary
  if [[ -n "${cleanup_output}" ]]; then
    mac_ops_log_debug "brew cleanup output: ${cleanup_output}"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Internal: Print one line per running executable under the Cellar whose keg is
# not the currently linked version of its formula ("<exec> uses keg <formula>
# <version>, linked: <version|none>"). A formula whose opt link cannot be
# resolved counts as not linked. Return 1 if the process list cannot be built.
# Usage: _mac_ops_brew_old_kegs_in_use
# -----------------------------------------------------------------------------
_mac_ops_brew_old_kegs_in_use() {
  local ps_out="" exec_path="" rest="" formula="" version="" linked="" opt_link=""
  local prefix=""
  local -A reported=()

  ps_out=$(ps -eo comm= 2>/dev/null)
  if [[ $? -ne 0 || -z "${ps_out}" ]]; then
    return 1
  fi
  prefix=$(brew --prefix 2>/dev/null)

  while IFS= read -r exec_path; do
    [[ "${exec_path}" == */Cellar/* ]] || continue
    rest="${exec_path#*/Cellar/}"
    formula="${rest%%/*}"
    version="${${rest#*/}%%/*}"
    [[ -z "${formula}" || -z "${version}" ]] && continue

    linked=""
    opt_link="${exec_path%%/Cellar/*}/opt/${formula}"
    [[ ! -L "${opt_link}" && -n "${prefix}" ]] && opt_link="${prefix}/opt/${formula}"
    if [[ -L "${opt_link}" && -d "${opt_link}" ]]; then
      linked="${opt_link:A:t}"
    fi

    if [[ "${version}" != "${linked}" ]]; then
      [[ -n "${reported[${exec_path}]:-}" ]] && continue
      reported[${exec_path}]=1
      print -r -- "${exec_path} uses keg ${formula} ${version}, linked: ${linked:-none}"
    fi
  done <<< "${ps_out}"
  return 0
}
