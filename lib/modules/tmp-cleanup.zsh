# =============================================================================
# mac-ops: Temp file cleanup module
# /tmp, /private/var/folders, ~/Library/Application Support/CrashReporter
# Different retention periods applied per path
# =============================================================================

# --- Default settings ---
MAC_OPS_TMP_MAX_AGE_DAYS=${MAC_OPS_TMP_MAX_AGE_DAYS:-3}
MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS=${MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS:-7}
MAC_OPS_CRASH_MAX_AGE_DAYS=${MAC_OPS_CRASH_MAX_AGE_DAYS:-14}

# --- Scan roots (overridable so tests can point the module at fixtures) ---
MAC_OPS_TMP_DIR=${MAC_OPS_TMP_DIR:-/tmp}
MAC_OPS_VAR_FOLDERS_DIR=${MAC_OPS_VAR_FOLDERS_DIR:-/private/var/folders}

# =============================================================================
# Shared file-cleanup guards (_mac_ops_fc_*)
# Used by the tmp, log, cache, browser, dev and brew modules.
# They live here because this module uses all of them; they could move to
# lib/utils later.
# =============================================================================

# --- Security software is never touched (case-insensitive path substrings) ---
MAC_OPS_SECURITY_KEYWORDS=(
  fortinet forticlient ahnlab astx jiran jkok pnpsecure pcassist wizvera
  delfino veraport iniline crossex initech inisafe nprotect raon touchen
)

# --- Per-run caches (built once on first use; tests may pre-seed them) ---
_MAC_OPS_FC_RUNNING_EXECS="${_MAC_OPS_FC_RUNNING_EXECS:-}"
_MAC_OPS_FC_OPEN_PATHS="${_MAC_OPS_FC_OPEN_PATHS:-}"
_MAC_OPS_FC_RUNNING_BUNDLES="${_MAC_OPS_FC_RUNNING_BUNDLES:-}"

# -----------------------------------------------------------------------------
# Return 0 if the path contains a security software keyword
# Usage: _mac_ops_fc_is_security_path <path>
# -----------------------------------------------------------------------------
_mac_ops_fc_is_security_path() {
  local lower_path="${1:l}"
  local keyword=""

  for keyword in "${MAC_OPS_SECURITY_KEYWORDS[@]}"; do
    if [[ "${lower_path}" == *"${keyword}"* ]]; then
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# Print the absolute local timestamp of "N days ago" for find -newermt/-newerat
# A relative date ("3 days ago") is rejected by bfs with "Invalid timestamp".
# Usage: _mac_ops_fc_cutoff_time <days>
# -----------------------------------------------------------------------------
_mac_ops_fc_cutoff_time() {
  local days="${1}"

  if [[ ! "${days}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  date -v-"${days}"d '+%Y-%m-%d %H:%M:%S'
}

# -----------------------------------------------------------------------------
# Look inside an item for anything that proves it is still in use:
# a socket or FIFO, any entry modified after the cutoff, or a file read after it.
# Prints the first hit. Return 0 = in use, 1 = nothing recent, 2 = check failed
# (callers must treat 2 like 0: a failed check never means "unused").
# Usage: _mac_ops_fc_live_entry <path> <cutoff timestamp>
# -----------------------------------------------------------------------------
_mac_ops_fc_live_entry() {
  local target="${1}"
  local cutoff="${2}"
  local hit=""
  local rc=0

  if [[ -z "${cutoff}" ]]; then
    return 2
  fi

  hit=$(find "${target}" \( -type s -o -type p -o -newermt "${cutoff}" \
    -o \( -type f -newerat "${cutoff}" \) \) -print -quit 2>/dev/null)
  rc=$?

  if [[ -n "${hit}" ]]; then
    print -r -- "${hit}"
    return 0
  fi
  if [[ ${rc} -ne 0 ]]; then
    return 2
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Build the list of running executables once per run (ps -eo comm=)
# Return 1 if the list cannot be built
# -----------------------------------------------------------------------------
_mac_ops_fc_load_running_execs() {
  local ps_out=""

  if [[ -n "${_MAC_OPS_FC_RUNNING_EXECS}" ]]; then
    return 0
  fi
  ps_out=$(ps -eo comm= 2>/dev/null)
  if [[ $? -ne 0 || -z "${ps_out}" ]]; then
    return 1
  fi
  _MAC_OPS_FC_RUNNING_EXECS="${ps_out}"
  return 0
}

# -----------------------------------------------------------------------------
# Return 0 if a running executable path contains one of the fragments
# (e.g. "/Google Chrome.app/"). Unknown process list counts as running.
# Usage: _mac_ops_fc_exec_running <path fragment>...
# -----------------------------------------------------------------------------
_mac_ops_fc_exec_running() {
  local fragment=""

  if ! _mac_ops_fc_load_running_execs; then
    return 0
  fi
  for fragment in "$@"; do
    if [[ "${_MAC_OPS_FC_RUNNING_EXECS}" == *"${fragment}"* ]]; then
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# Return 0 if a command-line tool is running: the executable is named <name>,
# or the process title is "<name> ..." (npm rewrites its title that way).
# Unknown process list counts as running.
# Usage: _mac_ops_fc_tool_running <name>...
# -----------------------------------------------------------------------------
_mac_ops_fc_tool_running() {
  local name=""
  local nl=$'\n'
  local haystack=""

  if ! _mac_ops_fc_load_running_execs; then
    return 0
  fi
  haystack="${nl}${_MAC_OPS_FC_RUNNING_EXECS}${nl}"
  for name in "$@"; do
    if [[ "${haystack}" == *"${nl}${name}${nl}"* \
       || "${haystack}" == *"/${name}${nl}"* \
       || "${haystack}" == *"${nl}${name} "* ]]; then
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# Return 0 if the package manager (or the runtime it runs on) is running
# pip and gradle run inside python/java, which is all `ps -eo comm` can show.
# Usage: _mac_ops_fc_manager_running <npm|yarn|pnpm|pip|uv|brew|gradle|pod>
# -----------------------------------------------------------------------------
_mac_ops_fc_manager_running() {
  case "${1}" in
    npm)    _mac_ops_fc_tool_running npm npx ;;
    yarn)   _mac_ops_fc_tool_running yarn yarnpkg ;;
    pnpm)   _mac_ops_fc_tool_running pnpm pnpx ;;
    pip)    _mac_ops_fc_tool_running pip pip3 || _mac_ops_fc_exec_running "/python" "/Python" ;;
    uv)     _mac_ops_fc_tool_running uv uvx ;;
    brew)   _mac_ops_fc_tool_running brew || _mac_ops_fc_exec_running "/Library/Homebrew/" ;;
    gradle) _mac_ops_fc_tool_running gradle gradlew java ;;
    pod)    _mac_ops_fc_tool_running pod ;;
    *)      return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# Return 0 if the name is the bundle ID of a running app or one of its
# sub-identifiers (com.example.app.helper for com.example.app).
# The list is built once per run. It is empty outside a GUI session, so this
# only adds to the open-file and recent-use checks, it never replaces them.
# Usage: _mac_ops_fc_bundle_running <directory name>
# -----------------------------------------------------------------------------
_mac_ops_fc_bundle_running() {
  local name="${1}"
  local bundle_id=""

  if [[ -z "${_MAC_OPS_FC_RUNNING_BUNDLES}" ]]; then
    _MAC_OPS_FC_RUNNING_BUNDLES=$(lsappinfo list 2>/dev/null | grep 'bundleID=' \
      | sed 's/.*bundleID="\([^"]*\)".*/\1/' | grep -v '^\[' | sort -u)
    _MAC_OPS_FC_RUNNING_BUNDLES="${_MAC_OPS_FC_RUNNING_BUNDLES:-none}"
  fi

  while IFS= read -r bundle_id; do
    [[ -z "${bundle_id}" ]] && continue
    if [[ "${name}" == "${bundle_id}" || "${name}" == "${bundle_id}."* ]]; then
      return 0
    fi
  done <<< "${_MAC_OPS_FC_RUNNING_BUNDLES}"
  return 1
}

# -----------------------------------------------------------------------------
# Build the list of paths held open by running processes once per run
# Return 1 if the list cannot be built
# -----------------------------------------------------------------------------
_mac_ops_fc_load_open_paths() {
  local lsof_out=""

  if [[ -n "${_MAC_OPS_FC_OPEN_PATHS}" ]]; then
    return 0
  fi
  # lsof exits non-zero whenever it cannot inspect another user's process,
  # so the output, not the exit status, tells whether the list is usable.
  lsof_out=$(lsof -Fn 2>/dev/null | grep '^n/' | grep -v -E '^n/(System|usr|bin|sbin|dev|Applications|Library)/')
  if [[ -z "${lsof_out}" ]]; then
    return 1
  fi
  _MAC_OPS_FC_OPEN_PATHS="${lsof_out}"
  return 0
}

# -----------------------------------------------------------------------------
# Return 0 if the path, or anything below it, is open in a running process,
# 1 if not, 2 if the open-file list is unavailable
# Usage: _mac_ops_fc_is_open <path>
# -----------------------------------------------------------------------------
_mac_ops_fc_is_open() {
  local target="${1:A}"
  local nl=$'\n'
  local haystack=""

  if ! _mac_ops_fc_load_open_paths; then
    return 2
  fi
  haystack="${nl}${_MAC_OPS_FC_OPEN_PATHS}${nl}"
  if [[ "${haystack}" == *"${nl}n${target}${nl}"* || "${haystack}" == *"${nl}n${target}/"* ]]; then
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Gate called before every move: return 0 if the item may be moved, or return 1
# after logging the reason at debug level.
# Checks, cheapest first: security software path, socket/FIFO, open by a
# running process, and (only when a cutoff argument is given) recent use inside.
# Usage: _mac_ops_fc_guard <path> <module> [cutoff timestamp]
# -----------------------------------------------------------------------------
_mac_ops_fc_guard() {
  local item="${1}"
  local module="${2}"
  local cutoff="${3:-}"
  local reason=""
  local hit=""
  local rc=0

  if _mac_ops_fc_is_security_path "${item}"; then
    reason="security software path"
  elif [[ -S "${item}" ]]; then
    reason="socket"
  elif [[ -p "${item}" ]]; then
    reason="FIFO"
  else
    _mac_ops_fc_is_open "${item}"
    rc=$?
    if [[ ${rc} -eq 0 ]]; then
      reason="open by a running process"
    elif [[ ${rc} -ne 1 ]]; then
      reason="open-file list unavailable"
    elif [[ $# -ge 3 ]]; then
      hit=$(_mac_ops_fc_live_entry "${item}" "${cutoff}")
      rc=$?
      if [[ ${rc} -eq 0 ]]; then
        if [[ -S "${hit}" ]]; then
          reason="socket inside: ${hit}"
        elif [[ -p "${hit}" ]]; then
          reason="FIFO inside: ${hit}"
        else
          reason="used after ${cutoff}: ${hit}"
        fi
      elif [[ ${rc} -ne 1 ]]; then
        reason="recent-use check failed"
      fi
    fi
  fi

  if [[ -n "${reason}" ]]; then
    mac_ops_log_debug "Protected, skipped (${module}): ${item} (reason: ${reason})"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Temp file cleanup main function
# Cleanup based on /tmp (3 days), /private/var/folders (7 days), CrashReporter (14 days)
# -----------------------------------------------------------------------------
mac_ops_tmp_cleanup() {
  mac_ops_log_info "Temp file cleanup started"

  # 1. /tmp cleanup (conservative handling as it's cleared on system reboot)
  _mac_ops_tmp_clean_path "${MAC_OPS_TMP_DIR}" "${MAC_OPS_TMP_MAX_AGE_DAYS}" "tmp-expired"

  # 2. /private/var/folders cleanup (user area only, accessible without sudo)
  _mac_ops_tmp_clean_var_folders "${MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS}"

  # 3. CrashReporter cleanup
  local crash_dir="${HOME}/Library/Application Support/CrashReporter"
  if [[ -d "${crash_dir}" ]]; then
    _mac_ops_tmp_clean_path "${crash_dir}" "${MAC_OPS_CRASH_MAX_AGE_DAYS}" "crash-report-expired"
  fi

  mac_ops_log_info "Temp file cleanup completed"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Print why a temp item is protected by its name (empty = not protected)
# These belong to live daemons, updaters and running agents.
# Usage: _mac_ops_tmp_protected_name <basename>
# -----------------------------------------------------------------------------
_mac_ops_tmp_protected_name() {
  case "${1}" in
    TemporaryItems)    print -- "TemporaryItems belongs to running apps" ;;
    com.apple.*)       print -- "com.apple.* item" ;;
    *.code_sign_clone) print -- "code-sign clone (APFS clone, moving it frees nothing)" ;;
    claude-*)          print -- "agent scratch directory" ;;
  esac
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Cleanup stale top-level items of the specified directory
# An item is moved as a whole, and only when nothing inside it was modified or
# read within the threshold (a directory's own mtime says nothing about use).
# Usage: _mac_ops_tmp_clean_path <path> <max_days> <reason>
# -----------------------------------------------------------------------------
_mac_ops_tmp_clean_path() {
  local target_dir="${1}"
  local max_age_days="${2}"
  local reason="${3}"
  local item=""
  local name_reason=""
  local cutoff=""
  local inner_file=""
  local count=0
  local file_size=0

  if [[ ! -d "${target_dir}" ]]; then
    mac_ops_log_debug "Path does not exist: ${target_dir}"
    return 0
  fi

  # Resolve symlinks (/tmp -> /private/tmp) so items match the open-file list
  target_dir="${target_dir:A}"

  cutoff=$(_mac_ops_fc_cutoff_time "${max_age_days}")
  if [[ $? -ne 0 || -z "${cutoff}" ]]; then
    mac_ops_log_warn "Cannot compute age cutoff (${max_age_days} days), skipping: ${target_dir}"
    return 0
  fi

  mac_ops_log_info "${target_dir} cleanup started (threshold: ${max_age_days} days or older)"

  count=0
  for item in "${target_dir}"/*(DN); do
    # Protected by name
    name_reason=$(_mac_ops_tmp_protected_name "${item:t}")
    if [[ -n "${name_reason}" ]]; then
      mac_ops_log_debug "Protected, skipped (tmp-cleanup): ${item} (reason: ${name_reason})"
      continue
    fi

    # Per-app temp/cache directory of an app that is running
    if _mac_ops_fc_bundle_running "${item:t}"; then
      mac_ops_log_debug "Protected, skipped (tmp-cleanup): ${item} (reason: owning app is running)"
      continue
    fi

    # Only items owned by the current user (others cannot be moved without sudo)
    if [[ ! -O "${item}" ]]; then
      mac_ops_log_debug "Protected, skipped (tmp-cleanup): ${item} (reason: not owned by ${USER})"
      continue
    fi

    # Security software, socket/FIFO, open by a process, recently used inside
    if ! _mac_ops_fc_guard "${item}" "tmp-cleanup" "${cutoff}"; then
      continue
    fi

    # A directory tree without files frees nothing, and daemons keep such
    # directories as their temp roots (a failed search is treated the same)
    if [[ -d "${item}" && ! -L "${item}" ]]; then
      inner_file=$(find "${item}" -type f -print -quit 2>/dev/null)
      if [[ -z "${inner_file}" ]]; then
        mac_ops_log_debug "Protected, skipped (tmp-cleanup): ${item} (reason: no files inside, nothing to free)"
        continue
      fi
    fi

    # Safety check
    if ! mac_ops_is_path_safe "${item}"; then
      continue
    fi

    # Size guard check
    if ! mac_ops_check_size_guard "${item}"; then
      continue
    fi

    # User ignore rules: path pattern
    if mac_ops_ignore_check_path "${item}"; then
      mac_ops_log_debug "User ignore (path): ${item}"
      continue
    fi

    # Record item size
    file_size=$(mac_ops_get_dir_size "${item}")

    # Move to trash
    if mac_ops_trash_move "${item}" "${reason}" "tmp-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done

  mac_ops_log_info "${target_dir}: ${count} items cleaned"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Cleanup /private/var/folders user area
# Process only the current user's T (temp), C (cache) and X directories
# Usage: _mac_ops_tmp_clean_var_folders <max_days>
# -----------------------------------------------------------------------------
_mac_ops_tmp_clean_var_folders() {
  local max_age_days="${1}"
  local var_folders="${MAC_OPS_VAR_FOLDERS_DIR}"
  local user_dir=""
  local sub=""

  if [[ ! -d "${var_folders}" ]]; then
    mac_ops_log_debug "Path does not exist: ${var_folders}"
    return 0
  fi

  mac_ops_log_info "${var_folders} cleanup started (threshold: ${max_age_days} days or older)"

  for user_dir in "${var_folders}"/*/*(/N); do
    # Other users' folders are not accessible without sudo
    [[ -O "${user_dir}" ]] || continue

    for sub in T C X; do
      if [[ -d "${user_dir}/${sub}" ]]; then
        _mac_ops_tmp_clean_path "${user_dir}/${sub}" "${max_age_days}" "var-folders-expired"
      fi
    done
  done

  return 0
}
