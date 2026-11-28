# =============================================================================
# mac-ops: Temp file cleanup module
# /tmp, /private/var/folders, ~/Library/Application Support/CrashReporter
# Different retention periods applied per path
# =============================================================================

# --- Default settings ---
# This module uses zsh-only syntax (parameter flags, nested expansions) that the bash-mode
# linter cannot parse; these three checks are false positives for the whole file.
# shellcheck disable=SC2296,SC2066,SC2299

MAC_OPS_TMP_MAX_AGE_DAYS=${MAC_OPS_TMP_MAX_AGE_DAYS:-3}
MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS=${MAC_OPS_VAR_FOLDERS_MAX_AGE_DAYS:-7}
MAC_OPS_CRASH_MAX_AGE_DAYS=${MAC_OPS_CRASH_MAX_AGE_DAYS:-14}

# --- Scan roots (test-only: tests point the module at fixtures; not a user setting) ---
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
_MAC_OPS_FC_RUNNING_APP_NAMES="${_MAC_OPS_FC_RUNNING_APP_NAMES:-}"
_MAC_OPS_FC_RUNNING_APPS_STATE="${_MAC_OPS_FC_RUNNING_APPS_STATE:-}"

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
# Build the list of running executables once per module (ps -eo comm=)
# Processes started by this mac-ops run (its own brew, find, ps calls, in any
# parallel module) are left out: they are not someone else using a cache.
# A process is ours when walking its parent links reaches the run's PID ($$,
# which stays the main shell's PID inside the module subshells).
# Return 1 if the list cannot be built
# -----------------------------------------------------------------------------
_mac_ops_fc_load_running_execs() {
  local ps_out=""
  local line="" pid="" ppid="" comm="" cur="" hops=0 ours=0
  local -A parent_of=()
  local -a lines=() kept=()

  if [[ -n "${_MAC_OPS_FC_RUNNING_EXECS}" ]]; then
    return 0
  fi
  ps_out=$(ps -eo pid=,ppid=,comm= 2>/dev/null)
  if [[ $? -ne 0 || -z "${ps_out}" ]]; then
    return 1
  fi

  lines=("${(@f)ps_out}")
  for line in "${lines[@]}"; do
    read -r pid ppid comm <<< "${line}"
    [[ "${pid}" =~ ^[0-9]+$ && "${ppid}" =~ ^[0-9]+$ ]] && parent_of[${pid}]="${ppid}"
  done

  for line in "${lines[@]}"; do
    read -r pid ppid comm <<< "${line}"
    [[ -z "${comm}" ]] && continue

    ours=0
    cur="${pid}"
    hops=0
    while [[ -n "${cur}" && "${cur}" -gt 1 && ${hops} -lt 64 ]]; do
      if [[ "${cur}" == "$$" ]]; then
        ours=1
        break
      fi
      cur="${parent_of[${cur}]:-}"
      hops=$((hops + 1))
    done
    [[ ${ours} -eq 1 ]] && continue
    kept+=("${comm}")
  done

  if [[ ${#kept[@]} -eq 0 ]]; then
    return 1
  fi
  _MAC_OPS_FC_RUNNING_EXECS="${(F)kept}"
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
# Build the running-app set once per module:
#   _MAC_OPS_FC_RUNNING_BUNDLES   bundle IDs (lsappinfo, plus the
#                                 CFBundleIdentifier of every running .app)
#   _MAC_OPS_FC_RUNNING_APP_NAMES app names of every running .app ("Telegram")
# Return 1 if either source fails: the caller must then protect the item.
# -----------------------------------------------------------------------------
_mac_ops_fc_load_running_apps() {
  local lsapp_out="" exec_path="" app_path="" bundle_id=""
  local -a bundles=() names=()
  local -A seen_app=()

  case "${_MAC_OPS_FC_RUNNING_APPS_STATE:-}" in
    ok)          return 0 ;;
    unavailable) return 1 ;;
  esac
  _MAC_OPS_FC_RUNNING_APPS_STATE="unavailable"

  # 1. Bundle IDs from Launch Services (tests may pre-seed the list)
  if [[ -n "${_MAC_OPS_FC_RUNNING_BUNDLES}" ]]; then
    bundles=("${(@f)_MAC_OPS_FC_RUNNING_BUNDLES}")
  else
    lsapp_out=$(lsappinfo list 2>/dev/null)
    if [[ $? -ne 0 ]]; then
      return 1
    fi
    bundles=("${(@f)$(print -r -- "${lsapp_out}" | grep 'bundleID="' \
      | sed 's/.*bundleID="\([^"]*\)".*/\1/' | grep -v '^\[')}")
    bundles=("${(@)bundles:#}")
    if [[ ${#bundles[@]} -eq 0 ]]; then
      return 1
    fi
  fi

  # 2. Every running .app from the executable paths
  if ! _mac_ops_fc_load_running_execs; then
    return 1
  fi
  for exec_path in "${(@f)_MAC_OPS_FC_RUNNING_EXECS}"; do
    [[ "${exec_path}" == /*.app/* ]] || continue
    app_path="${exec_path%%.app/*}.app"
    [[ -n "${seen_app[${app_path}]:-}" ]] && continue
    seen_app[${app_path}]=1
    names+=("${${app_path:t}%.app}")
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "${app_path}/Contents/Info.plist" 2>/dev/null)
    [[ -n "${bundle_id}" ]] && bundles+=("${bundle_id}")
  done

  _MAC_OPS_FC_RUNNING_BUNDLES="${(F)${(@u)bundles}}"
  _MAC_OPS_FC_RUNNING_APP_NAMES="${(F)${(@u)names}}"
  _MAC_OPS_FC_RUNNING_APPS_STATE="ok"
  return 0
}

# -----------------------------------------------------------------------------
# Return 0 if a directory name belongs to a running app, 1 if not,
# 2 if the running-app set cannot be built (callers treat 2 like 0).
# A name matches (case-insensitively) a running app's bundle ID or a
# sub-identifier of it (com.example.app.helper), the bundle ID's first two
# labels or anything below them (com.example.*), or the app's name (Telegram).
# Usage: _mac_ops_fc_app_running <directory name>
# -----------------------------------------------------------------------------
_mac_ops_fc_app_running() {
  local name="${1:l}"
  local bundle_id="" vendor="" app_name=""
  local -a labels=()

  if ! _mac_ops_fc_load_running_apps; then
    return 2
  fi

  for bundle_id in "${(@f)_MAC_OPS_FC_RUNNING_BUNDLES:l}"; do
    [[ -z "${bundle_id}" ]] && continue
    if [[ "${name}" == "${bundle_id}" || "${name}" == "${bundle_id}."* ]]; then
      return 0
    fi
    labels=("${(@s:.:)bundle_id}")
    if [[ ${#labels[@]} -ge 3 ]]; then
      vendor="${labels[1]}.${labels[2]}"
      if [[ "${name}" == "${vendor}" || "${name}" == "${vendor}."* ]]; then
        return 0
      fi
    fi
  done

  for app_name in "${(@f)_MAC_OPS_FC_RUNNING_APP_NAMES:l}"; do
    [[ -z "${app_name}" ]] && continue
    if [[ "${name}" == "${app_name}" ]]; then
      return 0
    fi
  done
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
# Internal: Set _MAC_OPS_TMP_TOP_REASON to why a top-level item is protected
# (empty = not protected). Runs in the caller's shell so the per-module
# process, open-file and running-app lists are built once, not per item.
# Checks: owning app running (or the running-app set unavailable), then the
# shared guard (security path, socket/FIFO, open, used after the cutoff).
# Usage: _mac_ops_tmp_top_reason <top-level item> <cutoff timestamp>
# -----------------------------------------------------------------------------
_mac_ops_tmp_top_reason() {
  local top="${1}"
  local cutoff="${2}"
  local rc=0

  _MAC_OPS_TMP_TOP_REASON=""
  _mac_ops_fc_app_running "${top:t}"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    _MAC_OPS_TMP_TOP_REASON="owning app is running"
    return 0
  elif [[ ${rc} -ne 1 ]]; then
    _MAC_OPS_TMP_TOP_REASON="running-app list unavailable"
    return 0
  fi

  if ! _mac_ops_fc_guard "${top}" "tmp-cleanup" "${cutoff}"; then
    _MAC_OPS_TMP_TOP_REASON="in use or protected"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Move the old files a find produced, after the protections.
# The candidate list is exactly what the released version selected (old regular
# files from the same find); the protections only ever remove candidates.
# Each candidate is checked by every path component below the top-level item
# (a nested com.apple.* directory protects what is inside it), by its top-level
# item (checked once and cached), and by itself.
# Usage: _mac_ops_tmp_clean_candidates <file list> <scan root> <top depth> \
#          <max_days> <reason> <label>
#   top depth: number of path components below <scan root> that name the
#   top-level item (1 for /tmp, 4 for /private/var/folders/xx/yyy/T/<item>)
# -----------------------------------------------------------------------------
_mac_ops_tmp_clean_candidates() {
  local file_list="${1}"
  local scan_root="${2%/}"
  local top_depth="${3}"
  local max_age_days="${4}"
  local reason="${5}"
  local label="${6}"
  local file_path="" rel="" top="" part="" name_reason="" top_reason="" cutoff=""
  local count=0
  local file_size=0
  local -a parts=()
  local -A top_reasons=()

  cutoff=$(_mac_ops_fc_cutoff_time "${max_age_days}")
  if [[ $? -ne 0 || -z "${cutoff}" ]]; then
    mac_ops_log_warn "Cannot compute age cutoff (${max_age_days} days), skipping: ${label}"
    return 0
  fi

  count=0
  while IFS= read -r file_path; do
    [[ -z "${file_path}" ]] && continue

    rel="${file_path#${scan_root}/}"
    parts=("${(@s:/:)rel}")
    if [[ ${#parts[@]} -gt ${top_depth} ]]; then
      top="${scan_root}/${(j:/:)parts[1,${top_depth}]}"
    else
      top="${file_path}"
    fi

    # Protected by the name of the top-level item or of anything below it
    name_reason=""
    for part in "${(@)parts[$(( ${#parts[@]} < top_depth ? ${#parts[@]} : top_depth )),-1]}"; do
      name_reason=$(_mac_ops_tmp_protected_name "${part}")
      [[ -n "${name_reason}" ]] && break
    done
    if [[ -n "${name_reason}" ]]; then
      mac_ops_log_debug "Protected, skipped (tmp-cleanup): ${file_path} (reason: ${name_reason})"
      continue
    fi

    # Only files owned by the current user (others cannot be moved without sudo)
    if [[ ! -O "${file_path}" ]]; then
      mac_ops_log_debug "Protected, skipped (tmp-cleanup): ${file_path} (reason: not owned by ${USER})"
      continue
    fi

    # The top-level item: owning app running, in use, security software
    if [[ -z "${top_reasons[${top}]+set}" ]]; then
      _mac_ops_tmp_top_reason "${top}" "${cutoff}"
      top_reasons[${top}]="${_MAC_OPS_TMP_TOP_REASON}"
    fi
    top_reason="${top_reasons[${top}]}"
    if [[ -n "${top_reason}" ]]; then
      mac_ops_log_debug "Protected, skipped (tmp-cleanup): ${file_path} (reason: top-level item ${top}: ${top_reason})"
      continue
    fi

    # The file itself: security software, open by a process, read recently
    if [[ "${top}" != "${file_path}" ]] && ! _mac_ops_fc_guard "${file_path}" "tmp-cleanup" "${cutoff}"; then
      continue
    fi

    # Safety check
    if ! mac_ops_is_path_safe "${file_path}"; then
      continue
    fi

    # Size guard check
    if ! mac_ops_check_size_guard "${file_path}"; then
      continue
    fi

    # User ignore rules: path pattern
    if mac_ops_ignore_check_path "${file_path}"; then
      mac_ops_log_debug "User ignore (path): ${file_path}"
      continue
    fi

    # Record file size
    file_size=$(mac_ops_get_dir_size "${file_path}")

    # Move to trash
    if mac_ops_trash_move "${file_path}" "${reason}" "tmp-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done <<< "${file_list}"

  mac_ops_log_info "${label}: ${count} files cleaned"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Search and cleanup old files in specified path
# The candidates are the released version's: old regular files up to depth 5.
# The path is passed to find as given (a symlinked root such as /tmp is not
# followed, exactly as before).
# Usage: _mac_ops_tmp_clean_path <path> <max_days> <reason>
# -----------------------------------------------------------------------------
_mac_ops_tmp_clean_path() {
  local target_dir="${1}"
  local max_age_days="${2}"
  local reason="${3}"
  local file_list=""

  if [[ ! -d "${target_dir}" ]]; then
    mac_ops_log_debug "Path does not exist: ${target_dir}"
    return 0
  fi

  mac_ops_log_info "${target_dir} cleanup started (threshold: ${max_age_days} days or older)"

  # Search old files with find (based on modification time)
  # Prevent too deep search with -maxdepth limit
  file_list=$(find "${target_dir}" -maxdepth 5 -type f -mtime "+${max_age_days}" 2>/dev/null)

  if [[ -z "${file_list}" ]]; then
    mac_ops_log_debug "${target_dir}: No cleanup targets"
    return 0
  fi

  _mac_ops_tmp_clean_candidates "${file_list}" "${target_dir}" 1 \
    "${max_age_days}" "${reason}" "${target_dir}"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Cleanup /private/var/folders user area
# The candidates are the released version's: old regular files of the current
# user up to depth 6. The top-level item of a candidate is
# /private/var/folders/xx/yyy/<T|C|X|0>/<item>.
# Usage: _mac_ops_tmp_clean_var_folders <max_days>
# -----------------------------------------------------------------------------
_mac_ops_tmp_clean_var_folders() {
  local max_age_days="${1}"
  local var_folders="${MAC_OPS_VAR_FOLDERS_DIR}"
  local file_list=""

  if [[ ! -d "${var_folders}" ]]; then
    mac_ops_log_debug "Path does not exist: ${var_folders}"
    return 0
  fi

  mac_ops_log_info "${var_folders} cleanup started (threshold: ${max_age_days} days or older)"

  # Search only files accessible by current user
  # Ignore permission errors with 2>/dev/null instead of -readable
  file_list=$(find "${var_folders}" -maxdepth 6 -type f -mtime "+${max_age_days}" \
    -user "${USER}" 2>/dev/null)

  if [[ -z "${file_list}" ]]; then
    mac_ops_log_debug "${var_folders}: No cleanup targets"
    return 0
  fi

  _mac_ops_tmp_clean_candidates "${file_list}" "${var_folders}" 4 \
    "${max_age_days}" "var-folders-expired" "${var_folders}"
  return 0
}
