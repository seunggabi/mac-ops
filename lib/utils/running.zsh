# lib/utils/running.zsh
# Running-process and running-app detection shared by the modules
# (tmp, log, cache, browser, dev and brew cleanup)
# zsh-only parameter flags and nested expansions; false positives in bash mode
# shellcheck disable=SC2296,SC2066,SC2299

# --- Per-run caches (built once on first use; tests may pre-seed them) ---
_MAC_OPS_FC_RUNNING_EXECS="${_MAC_OPS_FC_RUNNING_EXECS:-}"
_MAC_OPS_FC_RUNNING_BUNDLES="${_MAC_OPS_FC_RUNNING_BUNDLES:-}"
_MAC_OPS_FC_RUNNING_APP_NAMES="${_MAC_OPS_FC_RUNNING_APP_NAMES:-}"
_MAC_OPS_FC_RUNNING_APPS_STATE="${_MAC_OPS_FC_RUNNING_APPS_STATE:-}"

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
# Print the bundle IDs of running apps from Launch Services, one per line
# Return 1 if lsappinfo fails or lists no bundle ID.
# Usage: _mac_ops_running_bundle_ids
# -----------------------------------------------------------------------------
_mac_ops_running_bundle_ids() {
  local lsapp_out=""

  lsapp_out=$(lsappinfo list 2>/dev/null) || return 1
  print -r -- "${lsapp_out}" | grep 'bundleID="' \
    | sed 's/.*bundleID="\([^"]*\)".*/\1/' | grep -v '^\['
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
    lsapp_out=$(_mac_ops_running_bundle_ids) || return 1
    bundles=("${(@f)lsapp_out}")
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
