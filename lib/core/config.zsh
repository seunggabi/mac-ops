# =============================================================================
# mac-ops: Configuration loader
# Default path definitions, the settings registry and config.plist loading
# =============================================================================

# zsh-only parameter flags and nested expansions; false positives in bash mode
# shellcheck disable=SC2296,SC2299,SC2066

# --- Default paths ---
MAC_OPS_HOME="${MAC_OPS_HOME:-${HOME}/.mac-ops}"
MAC_OPS_TRASH_DIR="${MAC_OPS_TRASH_DIR:-${MAC_OPS_HOME}/.trash}"
MAC_OPS_META_DIR="${MAC_OPS_META_DIR:-${MAC_OPS_HOME}/.metadata}"
MAC_OPS_LOG_DIR="${MAC_OPS_LOG_DIR:-${MAC_OPS_HOME}/.logs}"
MAC_OPS_LOCK_FILE="${MAC_OPS_LOCK_FILE:-${MAC_OPS_HOME}/mac-ops.lock}"
MAC_OPS_CONFIG_FILE="${MAC_OPS_CONFIG_FILE:-${MAC_OPS_HOME}/config.plist}"

# -----------------------------------------------------------------------------
# Settings registry: one entry per user setting, "VAR|plist key path|default|type"
#   type: bool              true/false (yes/no/1/0 are accepted and normalised)
#         enable            module Enabled flags: only plist <true/>/<false/> or
#                           the exact strings "true"/"false". Any other value
#                           never enables a module: an "off" spelling
#                           (no/0/FALSE/off) disables it, anything else keeps
#                           the default; both are warned
#         int:MIN           integer >= MIN
#         int:MIN:MAX       integer >= MIN and <= MAX
#         enum:a,b,...      one of the listed values
# Precedence: environment variable > config.plist > built-in default.
# Command-line flags (--dry-run, --verbose, --force) override all three.
# A value that fails its type check falls back to the default with a WARN.
# Module defaults: only modules that move files to the mac-ops trash and are
# safe unattended are enabled. Process-ending modules (zombie-killer,
# orphan-killer), docker-cleanup and brew-cleanup (which deletes permanently)
# are disabled until the user enables them.
# -----------------------------------------------------------------------------
typeset -ga MAC_OPS_SETTINGS
MAC_OPS_SETTINGS=(
  "MAC_OPS_DRY_RUN|DryRun|false|bool"
  "MAC_OPS_VERBOSE|Verbose|false|bool"
  "MAC_OPS_FORCE|Force|false|bool"
  "MAC_OPS_TRASH_RETENTION_HOURS|TrashRetentionHours|72|int:1:8760"
  "MAC_OPS_MAX_SINGLE_FILE_BYTES|MaxSingleFileBytes|2147483648|int:1"
  "MAC_OPS_PARALLEL_TIMEOUT_SECONDS|ParallelTimeoutSeconds|300|int:1"
  "MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS|IndexLockTimeoutSeconds|120|int:1"
  "MAC_OPS_OPEN_FILES_TTL_SECONDS|OpenFilesTTLSeconds|60|int:0"
  "MAC_OPS_TRASH_SKIP_OPEN_DIRS|TrashSkipOpenDirs|true|bool"
  "MAC_OPS_TRASH_RECONCILE_MAX_DEPTH|TrashReconcileMaxDepth|6|int:1"
  "MAC_OPS_TRASH_RECOVERY_MIN_LEFT_HOURS|TrashRecoveryMinLeftHours|24|int:0"
  "MAC_OPS_MODULE_CACHE_CLEANUP_ENABLED|Modules.cache-cleanup.Enabled|true|enable"
  "MAC_OPS_CACHE_MAX_AGE_DAYS|Modules.cache-cleanup.MaxAgeDays|30|int:1"
  "MAC_OPS_CACHE_RECENT_DAYS|Modules.cache-cleanup.RecentDays|7|int:0"
  "MAC_OPS_MODULE_TMP_CLEANUP_ENABLED|Modules.tmp-cleanup.Enabled|true|enable"
  "MAC_OPS_TMP_MAX_AGE_DAYS|Modules.tmp-cleanup.MaxAgeDays|3|int:1"
  "MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS|Modules.tmp-cleanup.VarFoldersMaxAgeDays|7|int:1"
  "MAC_OPS_CRASH_MAX_AGE_DAYS|Modules.tmp-cleanup.CrashMaxAgeDays|14|int:1"
  "MAC_OPS_MODULE_LOG_CLEANUP_ENABLED|Modules.log-cleanup.Enabled|true|enable"
  "MAC_OPS_LOG_CLEANUP_MAX_AGE_DAYS|Modules.log-cleanup.MaxAgeDays|7|int:1"
  "MAC_OPS_DIAG_REPORT_MAX_AGE_DAYS|Modules.log-cleanup.DiagReportMaxAgeDays|30|int:1"
  "MAC_OPS_MODULE_ORPHAN_APP_CLEANUP_ENABLED|Modules.orphan-app-cleanup.Enabled|true|enable"
  "MAC_OPS_ORPHAN_APP_GRACE_DAYS|Modules.orphan-app-cleanup.GraceDays|7|int:0"
  "MAC_OPS_ORPHAN_APP_DATA_ACTION|Modules.orphan-app-cleanup.DataAction|report|enum:report,trash"
  "MAC_OPS_MODULE_BREW_CLEANUP_ENABLED|Modules.brew-cleanup.Enabled|false|enable"
  "MAC_OPS_MODULE_DEV_CLEANUP_ENABLED|Modules.dev-cleanup.Enabled|false|enable"
  "MAC_OPS_DEV_CACHE_MAX_AGE_DAYS|Modules.dev-cleanup.MaxAgeDays|30|int:1"
  "MAC_OPS_MODULE_BROWSER_CLEANUP_ENABLED|Modules.browser-cleanup.Enabled|false|enable"
  "MAC_OPS_MODULE_DOCKER_CLEANUP_ENABLED|Modules.docker-cleanup.Enabled|false|enable"
  "MAC_OPS_DOCKER_ACTION|Modules.docker-cleanup.Action|report|enum:report,prune"
  "MAC_OPS_DOCKER_PRUNE_UNTIL_HOURS|Modules.docker-cleanup.PruneUntilHours|720|int:1"
  "MAC_OPS_DOCKER_PROBE_TIMEOUT|Modules.docker-cleanup.ProbeTimeoutSeconds|10|int:1"
  "MAC_OPS_MODULE_ZOMBIE_KILLER_ENABLED|Modules.zombie-killer.Enabled|false|enable"
  "MAC_OPS_ZOMBIE_ACTION|Modules.zombie-killer.Action|report|enum:report,sigchld"
  "MAC_OPS_MODULE_ORPHAN_KILLER_ENABLED|Modules.orphan-killer.Enabled|false|enable"
  "MAC_OPS_ORPHAN_MIN_RUNNING_HOURS|Modules.orphan-killer.MinRunningHours|24|int:1"
  "MAC_OPS_ORPHAN_ACTION|Modules.orphan-killer.Action|report|enum:report,term"
  "MAC_OPS_MONITOR_RETENTION_DAYS|Monitor.RetentionDays|7|int:1"
  "MAC_OPS_MONITOR_KILL_THRESHOLD_MB|Monitor.KillThresholdMB|500|int:1"
  "MAC_OPS_NOTIFY_ON_SUCCESS|Notify.OnSuccess|false|bool"
  "MAC_OPS_NOTIFY_REPEAT_HOURS|Notify.FailureRepeatHours|24|int:1:8760"
)

# Where each setting's effective value came from: env, file, default or cli
typeset -gA MAC_OPS_SETTING_SOURCE

# Command-line flags, applied after the config file (VAR -> value)
typeset -gA MAC_OPS_CLI_OVERRIDES

# Values present before any default below is applied (environment, or set by
# the caller before sourcing). Captured first so defaults are not mistaken for
# user input.
typeset -gA _MAC_OPS_ENV_SETTINGS
_mac_ops_capture_env_settings() {
  local entry name
  for entry in "${MAC_OPS_SETTINGS[@]}"; do
    name="${entry%%|*}"
    if [[ -n "${(P)name}" ]]; then
      _MAC_OPS_ENV_SETTINGS[${name}]="${(P)name}"
    fi
  done
}
_mac_ops_capture_env_settings

# --- Default flags ---
MAC_OPS_DRY_RUN=${MAC_OPS_DRY_RUN:-false}
MAC_OPS_VERBOSE=${MAC_OPS_VERBOSE:-false}
MAC_OPS_FORCE=${MAC_OPS_FORCE:-false}
MAC_OPS_SCHEDULED=${MAC_OPS_SCHEDULED:-false}

# --- Default configuration values ---
MAC_OPS_TRASH_RETENTION_HOURS=${MAC_OPS_TRASH_RETENTION_HOURS:-72}

# -----------------------------------------------------------------------------
# Create required directories
# -----------------------------------------------------------------------------
mac_ops_init_dirs() {
  local dirs=(
    "${MAC_OPS_HOME}"
    "${MAC_OPS_TRASH_DIR}"
    "${MAC_OPS_META_DIR}"
    "${MAC_OPS_LOG_DIR}"
  )

  for dir in "${dirs[@]}"; do
    if [[ ! -d "${dir}" ]]; then
      mkdir -p "${dir}" 2>/dev/null
      if [[ $? -ne 0 ]]; then
        print -- "[ERROR] Failed to create directory: ${dir}" >&2
        return 1
      fi
    fi

    # Set directories to be accessible only by owner
    chmod 700 "${dir}" 2>/dev/null
  done

  return 0
}

# -----------------------------------------------------------------------------
# Log through the logger when it is loaded, else to stderr
# Usage: _mac_ops_config_log <WARN|ERROR> <message>
# -----------------------------------------------------------------------------
_mac_ops_config_log() {
  if (( ${+functions[mac_ops_log]} )); then
    mac_ops_log "$1" "$2"
  else
    print -r -- "[$1] $2" >&2
  fi
}

# -----------------------------------------------------------------------------
# Validate a value against a registry type. Prints the normalised value.
# Usage: _mac_ops_setting_validate <type> <value>; returns 1 when invalid
# -----------------------------------------------------------------------------
_mac_ops_setting_validate() {
  local type="$1" value="$2"
  case "${type}" in
    bool)
      case "${(L)value}" in
        true|yes|1)  print -r -- "true" ;;
        false|no|0)  print -r -- "false" ;;
        *)           return 1 ;;
      esac
      ;;
    enable)
      case "${value}" in
        true|false)  print -r -- "${value}" ;;
        *)           return 1 ;;
      esac
      ;;
    int:*)
      [[ "${value}" =~ ^[0-9]+$ ]] || return 1
      # Reject values that do not fit a 64-bit integer
      [[ ${#value} -le 18 ]] || return 1
      local bounds="${type#int:}"
      (( 10#${value} >= ${bounds%%:*} )) || return 1
      if [[ "${bounds}" == *:* ]]; then
        (( 10#${value} <= ${bounds#*:} )) || return 1
      fi
      print -r -- "$((10#${value}))"
      ;;
    enum:*)
      local -a allowed
      allowed=("${(@s:,:)${type#enum:}}")
      (( ${allowed[(Ie)${value}]} )) || return 1
      print -r -- "${value}"
      ;;
    *)
      return 1
      ;;
  esac
}

# -----------------------------------------------------------------------------
# An inexact "off" spelling of an Enabled flag (no, 0, off, FALSE, ...):
# disabling a module is always the safe direction, so it is honoured (with a
# WARN). Inexact "on" spellings (yes, 1, TRUE) never enable a module.
# Usage: _mac_ops_setting_off_spelling <type> <value>
# -----------------------------------------------------------------------------
_mac_ops_setting_off_spelling() {
  [[ "$1" == "enable" ]] || return 1
  case "${(L)2}" in
    false|no|0|off) return 0 ;;
  esac
  return 1
}

# -----------------------------------------------------------------------------
# Load configuration: resolve every registry setting, then apply CLI flags.
# A missing config file or a missing key means the built-in default.
# A config file that exists but cannot be parsed is an error: it is logged
# (log file and stderr) and the function returns 1 so the caller aborts
# instead of running with defaults the user did not choose.
# -----------------------------------------------------------------------------
mac_ops_load_config() {
  local have_file=false
  if [[ -e "${MAC_OPS_CONFIG_FILE}" ]]; then
    if [[ ! -f "${MAC_OPS_CONFIG_FILE}" || ! -r "${MAC_OPS_CONFIG_FILE}" ]] \
      || ! plutil -lint "${MAC_OPS_CONFIG_FILE}" &>/dev/null \
      || [[ "$(plutil -convert json -o - "${MAC_OPS_CONFIG_FILE}" 2>/dev/null | head -c 1)" != "{" ]]; then
      local msg="Cannot parse config file ${MAC_OPS_CONFIG_FILE} (not a readable property list with a dictionary at the top). Fix or remove it; aborting."
      if [[ ! -d "${MAC_OPS_LOG_DIR}" ]] && mkdir -p "${MAC_OPS_LOG_DIR}" 2>/dev/null; then
        chmod 700 "${MAC_OPS_LOG_DIR}" 2>/dev/null || true
      fi
      _mac_ops_config_log "ERROR" "${msg}"
      # The logger is silent on stderr in scheduled mode: say it there too
      if [[ "${MAC_OPS_SCHEDULED}" == "true" ]]; then
        print -r -- "[ERROR] ${msg}" >&2
      fi
      return 1
    fi
    have_file=true
  fi

  local entry name key def type rest raw val src invalid
  for entry in "${MAC_OPS_SETTINGS[@]}"; do
    name="${entry%%|*}"; rest="${entry#*|}"
    key="${rest%%|*}"; rest="${rest#*|}"
    def="${rest%%|*}"; type="${rest#*|}"

    # Precedence: valid environment value, then valid config file value,
    # then the built-in default. An invalid value warns and falls through.
    val="" src="" invalid=false
    if [[ -n "${_MAC_OPS_ENV_SETTINGS[${name}]+_}" ]]; then
      raw="${_MAC_OPS_ENV_SETTINGS[${name}]}"
      if val=$(_mac_ops_setting_validate "${type}" "${raw}"); then
        src="env"
      elif _mac_ops_setting_off_spelling "${type}" "${raw}"; then
        _mac_ops_config_log "WARN" "Inexact value '${raw}' for ${name} (environment, expected true or false); treating it as false"
        val="false" src="env"
      else
        _mac_ops_config_log "WARN" "Invalid value '${raw}' for ${name} (environment, expected ${type}); ignoring it"
        val="" invalid=true
      fi
    fi
    if [[ -z "${src}" && "${have_file}" == "true" ]] \
      && raw=$(plutil -extract "${key}" raw -o - "${MAC_OPS_CONFIG_FILE}" 2>/dev/null); then
      if val=$(_mac_ops_setting_validate "${type}" "${raw}"); then
        src="file"
      elif _mac_ops_setting_off_spelling "${type}" "${raw}"; then
        _mac_ops_config_log "WARN" "Inexact value '${raw}' for ${key} in ${MAC_OPS_CONFIG_FILE} (expected <true/> or <false/>); treating it as false"
        val="false" src="file"
      else
        _mac_ops_config_log "WARN" "Invalid value '${raw}' for ${key} in ${MAC_OPS_CONFIG_FILE} (expected ${type}); ignoring it"
        val="" invalid=true
      fi
    fi
    if [[ -z "${src}" && "${invalid}" == "true" ]]; then
      _mac_ops_config_log "WARN" "${name}: no valid value set, using default '${def}'"
    fi

    if [[ -z "${src}" ]]; then
      val="${def}"
      src="default"
    fi
    typeset -g "${name}=${val}"
    MAC_OPS_SETTING_SOURCE[${name}]="${src}"
  done

  # Command-line flags win over environment and config file
  for name in "${(@k)MAC_OPS_CLI_OVERRIDES}"; do
    typeset -g "${name}=${MAC_OPS_CLI_OVERRIDES[${name}]}"
    MAC_OPS_SETTING_SOURCE[${name}]="cli"
  done

  return 0
}

# -----------------------------------------------------------------------------
# Print every registry setting: name, effective value, source and plist key
# -----------------------------------------------------------------------------
mac_ops_print_settings() {
  local entry name key rest
  for entry in "${MAC_OPS_SETTINGS[@]}"; do
    name="${entry%%|*}"; rest="${entry#*|}"
    key="${rest%%|*}"
    printf '%-42s = %-12s (%s; key %s)\n' "${name}" "${(P)name}" \
      "${MAC_OPS_SETTING_SOURCE[${name}]:-default}" "${key}"
  done
}

# -----------------------------------------------------------------------------
# Module enable flag. Usage: mac_ops_module_enabled <plist module name>
# e.g. mac_ops_module_enabled cache-cleanup -> MAC_OPS_MODULE_CACHE_CLEANUP_ENABLED
# Unknown or unset counts as disabled.
# -----------------------------------------------------------------------------
mac_ops_module_enabled() {
  local var="MAC_OPS_MODULE_${(U)1//-/_}_ENABLED"
  [[ "${(P)var}" == "true" ]]
}
