# =============================================================================
# mac-ops: Module selection and dispatch for the run command
# =============================================================================

# zsh-only parameter flags and nested expansions; false positives in bash mode
# shellcheck disable=SC2296,SC2299

# --- Module table: CLI name -> config name and function, in run order ---
# File modules run in parallel first, process modules sequentially after.
typeset -ga MAC_OPS_FILE_MODULES MAC_OPS_PROCESS_MODULES
MAC_OPS_FILE_MODULES=(cache tmp log orphan-app brew dev docker browser)
MAC_OPS_PROCESS_MODULES=(zombie orphan)

typeset -gA MAC_OPS_MODULE_MAP MAC_OPS_MODULE_CONFIG_NAME
MAC_OPS_MODULE_MAP=(
  cache       mac_ops_cache_cleanup
  tmp         mac_ops_tmp_cleanup
  log         mac_ops_log_cleanup
  zombie      mac_ops_zombie_killer
  orphan      mac_ops_orphan_killer
  orphan-app  mac_ops_orphan_app_cleanup
  brew        mac_ops_brew_cleanup
  dev         mac_ops_dev_cleanup
  docker      mac_ops_docker_cleanup
  browser     mac_ops_browser_cleanup
)
MAC_OPS_MODULE_CONFIG_NAME=(
  cache       cache-cleanup
  tmp         tmp-cleanup
  log         log-cleanup
  zombie      zombie-killer
  orphan      orphan-killer
  orphan-app  orphan-app-cleanup
  brew        brew-cleanup
  dev         dev-cleanup
  docker      docker-cleanup
  browser     browser-cleanup
)

# -----------------------------------------------------------------------------
# Is a module (CLI name) enabled? Logs exactly one line when it is not.
# Usage: mac_ops_module_selected <cli name>
# -----------------------------------------------------------------------------
mac_ops_module_selected() {
  local mod="$1"
  local cfg="${MAC_OPS_MODULE_CONFIG_NAME[${mod}]}"
  if mac_ops_module_enabled "${cfg}"; then
    return 0
  fi
  mac_ops_log_info "Module ${cfg} is disabled, skipped. To enable it set Modules.${cfg}.Enabled to true in ${MAC_OPS_CONFIG_FILE}, or MAC_OPS_MODULE_${(U)cfg//-/_}_ENABLED=true (run once: mac-ops run --module=${mod})"
  return 1
}

# -----------------------------------------------------------------------------
# Run the selected modules.
# Usage: mac_ops_run_modules <target_module or ""> <stats_dir>
# With a target (--module=NAME) only that module runs, even when it is
# disabled in the configuration: an explicit request is honoured and logged.
# Without a target every enabled module runs. Updates MAC_OPS_CLEANED_COUNT,
# MAC_OPS_CLEANED_BYTES and MAC_OPS_DATA_MOVED_COUNT. Returns 1 for an
# unknown module.
# Parallel modules run in subshells; each writes "<count> <bytes> <data moved>"
# to <stats_dir>/<function>.stats, summed here afterwards.
# -----------------------------------------------------------------------------
mac_ops_run_modules() {
  local target_module="$1"
  local stats_dir="$2"
  local mod func cfg mod_count mod_bytes mod_data stats_file

  if [[ -n "${target_module}" ]]; then
    if [[ -z "${MAC_OPS_MODULE_MAP[${target_module}]+_}" ]]; then
      mac_ops_log_error "Unknown module: ${target_module}"
      return 1
    fi
    func="${MAC_OPS_MODULE_MAP[${target_module}]}"
    cfg="${MAC_OPS_MODULE_CONFIG_NAME[${target_module}]}"
    if mac_ops_module_enabled "${cfg}"; then
      mac_ops_log_info "Running module: ${target_module} (${func})"
    else
      mac_ops_log_info "Running module: ${target_module} (${func}) - disabled in configuration (Modules.${cfg}.Enabled), explicitly requested with --module=${target_module}"
    fi
    ${func} || true
    return 0
  fi

  local -a pids=()
  mac_ops_log_info "Starting parallel execution of file cleanup modules (timeout: ${MAC_OPS_PARALLEL_TIMEOUT_SECONDS:-300}s per module)"
  for mod in "${MAC_OPS_FILE_MODULES[@]}"; do
    mac_ops_module_selected "${mod}" || continue
    func="${MAC_OPS_MODULE_MAP[${mod}]}"
    (
      MAC_OPS_CLEANED_COUNT=0
      MAC_OPS_CLEANED_BYTES=0
      MAC_OPS_DATA_MOVED_COUNT=0
      ${func} || true
      # Record statistics to file
      print "${MAC_OPS_CLEANED_COUNT} ${MAC_OPS_CLEANED_BYTES} ${MAC_OPS_DATA_MOVED_COUNT}" > "${stats_dir}/${func}.stats"
    ) &
    pids+=($!)
  done

  if [[ ${#pids[@]} -gt 0 ]]; then
    mac_ops_parallel_wait_with_timeout "${MAC_OPS_PARALLEL_TIMEOUT_SECONDS:-300}" "${pids[@]}" || \
      mac_ops_log_warn "Some modules timed out or failed during parallel execution"
  fi

  # Sum up from statistics files
  # shellcheck disable=SC1073,SC1036,SC1058,SC1072
  for stats_file in "${stats_dir}"/*.stats(N); do
    [[ ! -f "${stats_file}" ]] && continue
    mod_count=0; mod_bytes=0; mod_data=0
    read -r mod_count mod_bytes mod_data < "${stats_file}" 2>/dev/null || continue
    [[ "${mod_count}" =~ ^[0-9]+$ ]] || mod_count=0
    [[ "${mod_bytes}" =~ ^[0-9]+$ ]] || mod_bytes=0
    [[ "${mod_data}" =~ ^[0-9]+$ ]] || mod_data=0
    MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + mod_count))
    MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + mod_bytes))
    MAC_OPS_DATA_MOVED_COUNT=$((MAC_OPS_DATA_MOVED_COUNT + mod_data))
  done

  mac_ops_log_info "Starting sequential execution of process modules"
  for mod in "${MAC_OPS_PROCESS_MODULES[@]}"; do
    mac_ops_module_selected "${mod}" || continue
    ${MAC_OPS_MODULE_MAP[${mod}]} || true
  done
  return 0
}
