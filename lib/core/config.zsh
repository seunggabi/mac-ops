# =============================================================================
# mac-ops: Configuration loader
# Default path definitions and config.plist loading
# =============================================================================

# --- Default paths ---
MAC_OPS_HOME="${MAC_OPS_HOME:-${HOME}/.mac-ops}"
MAC_OPS_TRASH_DIR="${MAC_OPS_TRASH_DIR:-${MAC_OPS_HOME}/.trash}"
MAC_OPS_META_DIR="${MAC_OPS_META_DIR:-${MAC_OPS_HOME}/.metadata}"
MAC_OPS_LOG_DIR="${MAC_OPS_LOG_DIR:-${MAC_OPS_HOME}/.logs}"
MAC_OPS_LOCK_FILE="${MAC_OPS_LOCK_FILE:-${MAC_OPS_HOME}/mac-ops.lock}"
MAC_OPS_CONFIG_FILE="${MAC_OPS_CONFIG_FILE:-${MAC_OPS_HOME}/config.plist}"

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
# Load configuration from config.plist (using plutil)
# If file does not exist, keep default values.
# -----------------------------------------------------------------------------
mac_ops_load_config() {
  # If config.plist does not exist, use default values
  if [[ ! -f "${MAC_OPS_CONFIG_FILE}" ]]; then
    return 0
  fi

  # Validate plist
  if ! plutil -lint "${MAC_OPS_CONFIG_FILE}" &>/dev/null; then
    print -- "[ERROR] Invalid config.plist format: ${MAC_OPS_CONFIG_FILE}" >&2
    return 1
  fi

  # Load each configuration value (keep default if key does not exist)
  local val

  val=$(plutil -extract DryRun raw "${MAC_OPS_CONFIG_FILE}" 2>/dev/null)
  [[ -n "${val}" ]] && MAC_OPS_DRY_RUN="${val}"

  val=$(plutil -extract Verbose raw "${MAC_OPS_CONFIG_FILE}" 2>/dev/null)
  [[ -n "${val}" ]] && MAC_OPS_VERBOSE="${val}"

  val=$(plutil -extract Force raw "${MAC_OPS_CONFIG_FILE}" 2>/dev/null)
  [[ -n "${val}" ]] && MAC_OPS_FORCE="${val}"

  val=$(plutil -extract Scheduled raw "${MAC_OPS_CONFIG_FILE}" 2>/dev/null)
  [[ -n "${val}" ]] && MAC_OPS_SCHEDULED="${val}"

  val=$(plutil -extract TrashRetentionHours raw "${MAC_OPS_CONFIG_FILE}" 2>/dev/null)
  [[ -n "${val}" ]] && MAC_OPS_TRASH_RETENTION_HOURS="${val}"

  return 0
}
