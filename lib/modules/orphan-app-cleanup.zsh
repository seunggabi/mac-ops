# =============================================================================
# mac-ops: Orphan app data cleanup module
# Detect and cleanup leftover files from deleted apps (Application Support, Caches, Preferences, etc.)
# Excludes com.apple.*, Group Containers, systemgroup.*, security software, and
# entries that were modified (or hold a file modified) within the grace period
#
# Settings and data are not cache: an orphan in a data-bearing location
# (Application Support, Preferences, Containers, HTTPStorages, WebKit) is only reported
# unless the user opts in with MAC_OPS_ORPHAN_APP_DATA_ACTION=trash.
# =============================================================================

# --- Default settings ---
MAC_OPS_ORPHAN_APP_GRACE_DAYS=${MAC_OPS_ORPHAN_APP_GRACE_DAYS:-7}

# What to do with an orphan found in a settings/data location:
#   report (default) - log it with its size and the checks it passed, move nothing
#   trash            - move it to the mac-ops trash like a cache orphan
# Only the exact value "trash" moves anything. Every other value, including an
# empty one, "Trash" or "trash " with a trailing space, behaves like "report".
MAC_OPS_ORPHAN_APP_DATA_ACTION=${MAC_OPS_ORPHAN_APP_DATA_ACTION:-report}

# --- Cache-like locations (matched by directory name) ---
# An orphan here can be rebuilt by its app, so it is moved to the trash.
# Every scan location that is NOT listed here is treated as settings/data.
# HTTPStorages and WebKit are deliberately absent: HTTPStorages holds cookies
# (logins) and WebKit holds per-app web storage (local storage, IndexedDB).
_MAC_OPS_ORPHAN_APP_CACHE_DIR_NAMES=(
  "Caches"
  "Saved Application State"
)

# --- Scan target paths ---
MAC_OPS_ORPHAN_APP_SCAN_DIRS=(
  "${HOME}/Library/Application Support"
  "${HOME}/Library/Caches"
  "${HOME}/Library/Preferences"
  "${HOME}/Library/Saved Application State"
  "${HOME}/Library/Containers"
  "${HOME}/Library/HTTPStorages"
  "${HOME}/Library/WebKit"
)

# -----------------------------------------------------------------------------
# Safety safelist: bundle ID prefixes that must NEVER be deleted regardless of
# whether detection (mdfind / path scan / launchd) finds the app or not.
# Acts as a second line of defense. Keep alphabetically sorted per vendor group.
# -----------------------------------------------------------------------------
_MAC_OPS_BUNDLE_SAFELIST=(
  # --- JetBrains (com.jetbrains.* and bare jetbrains.* for helper plists) ---
  "com.jetbrains."
  "jetbrains."

  # --- Google / Chromium ---
  "com.google."
  "org.chromium."

  # --- Mozilla ---
  "org.mozilla."

  # --- Microsoft ---
  "com.microsoft."

  # --- Adobe ---
  "com.adobe."

  # --- Korean apps ---
  "com.kakao."
  "com.naver."
  "io.naver."

  # --- Korean banking / security software ---
  # AhnLab V3, TouchEN nxKey, INISAFE CrossWeb EX, etc.
  "com.ahnlab."
  "com.initech."
  "com.raon."
  "com.softforum."
  "kr.co."

  # --- Communication ---
  "com.discord."
  "com.slack."
  "com.tinyspeck."
  "net.whatsapp."
  "com.spotify."
  "us.zoom."

  # --- Productivity / Creative ---
  "com.atlassian."
  "com.dropbox."
  "com.figma."
  "com.notion."

  # --- Developer tools ---
  "com.brave."
  "com.cursor."
  "com.docker."
  "com.github."
  "com.sublimetext."
  "com.visualstudio."
  "com.xk72."
  "dev.zed."

  # --- Utilities / Automation ---
  "com.raycast."

  # --- Virtualization ---
  "com.parallels."
  "com.vmware."
)

# -----------------------------------------------------------------------------
# Internal: Check if a bundle ID name is in the safelist
# Returns 0 (true) if protected, 1 (false) if not
# Usage: _mac_ops_is_safelisted <name>
# -----------------------------------------------------------------------------
_mac_ops_is_safelisted() {
  local name="${1}"
  local prefix
  for prefix in "${_MAC_OPS_BUNDLE_SAFELIST[@]}"; do
    if [[ "${name}" == "${prefix}"* ]]; then
      return 0
    fi
  done
  return 1
}

# Security software (MAC_OPS_SECURITY_KEYWORDS, lib/utils/security-keywords.zsh)
# is never touched: endpoint security, VPN and Korean banking security
# products use many bundle ID prefixes, and removing their data can break
# logins or trigger a reinstall. Matched case-insensitively anywhere in the
# entry name.

# -----------------------------------------------------------------------------
# Internal: Check if a scan location is cache-like (see the list at the top)
# Returns 0 (true) if cache-like, 1 (false) if it holds settings/data
# Usage: _mac_ops_orphan_app_is_cache_location <scan_dir>
# -----------------------------------------------------------------------------
_mac_ops_orphan_app_is_cache_location() {
  local dir_name
  dir_name=$(basename "${1}")
  local cache_name
  for cache_name in "${_MAC_OPS_ORPHAN_APP_CACHE_DIR_NAMES[@]}"; do
    if [[ "${dir_name}" == "${cache_name}" ]]; then
      return 0
    fi
  done
  return 1
}

# -----------------------------------------------------------------------------
# Reverse-domain bundle ID name: at least three labels separated by literal
# dots (com.example.app), made of letters, digits, "-" and "_" only. The first
# label starts with a letter; later labels may start with a digit
# (com.1password.1password, org.7-zip.7zip). The pattern is anchored at both
# ends, so a name with a space or any other character is not a bundle ID.
#
# The pattern lives in a variable on purpose: zsh removes the backslash from an
# unquoted \. inside [[ =~ ]], which turns each dot into "any character" and
# makes the pattern match every name of five or more characters (JetBrains,
# Naver, Garmin, iTerm2). A variable's value is used as the regex unchanged.
# -----------------------------------------------------------------------------
typeset -g _MAC_OPS_BUNDLE_ID_RE='^[a-zA-Z][a-zA-Z0-9_-]*\.[a-zA-Z0-9][a-zA-Z0-9_-]*(\.[a-zA-Z0-9_-]+)+$'

# -----------------------------------------------------------------------------
# Internal: Check if a name looks like a reverse-domain bundle ID
# Returns 0 (true) if it does, 1 (false) if not
# Usage: _mac_ops_is_bundle_id_name <name>
# -----------------------------------------------------------------------------
_mac_ops_is_bundle_id_name() {
  [[ "${1}" =~ ${_MAC_OPS_BUNDLE_ID_RE} ]]
}

# -----------------------------------------------------------------------------
# Internal: Print the vendor of a bundle ID: its first two labels, lowercased
# (com.garmin.renu.service -> com.garmin). Prints nothing for a name with fewer
# than two non-empty labels.
# Usage: _mac_ops_orphan_app_vendor <bundle_id>
# -----------------------------------------------------------------------------
_mac_ops_orphan_app_vendor() {
  local id="${1}"
  [[ "${id}" == *.* ]] || return 0
  local first="${id%%.*}"
  local rest="${id#*.}"
  local second="${rest%%.*}"
  [[ -n "${first}" && -n "${second}" ]] || return 0
  print -r -- "${(L)first}.${(L)second}"
}

# -----------------------------------------------------------------------------
# Internal: Build _MAC_OPS_INSTALLED_VENDORS from _MAC_OPS_INSTALLED_BUNDLES.
# An entry that shares its vendor with any installed bundle ID is protected:
# helpers, login items and services of an installed app often use bundle IDs
# that no detection source reports (com.garmin.renu.service next to the
# installed com.garmin.renu.client).
# Usage: _mac_ops_orphan_app_build_vendor_index
# -----------------------------------------------------------------------------
_mac_ops_orphan_app_build_vendor_index() {
  typeset -gA _MAC_OPS_INSTALLED_VENDORS
  _MAC_OPS_INSTALLED_VENDORS=()
  local id first rest second
  for id in "${(@k)_MAC_OPS_INSTALLED_BUNDLES}"; do
    [[ "${id}" == *.* ]] || continue
    first="${id%%.*}"
    rest="${id#*.}"
    second="${rest%%.*}"
    [[ -n "${first}" && -n "${second}" ]] || continue
    _MAC_OPS_INSTALLED_VENDORS[${(L)first}.${(L)second}]=1
  done
}

# -----------------------------------------------------------------------------
# Orphan app data cleanup main function
# 1. Extract bundle IDs of installed apps from /Applications, ~/Applications,
#    Spotlight (mdfind), Homebrew Cask, and LaunchDaemons/Agents
# 2. Search for bundle ID pattern directories/files in scan target paths
# 3. If not in installed apps list, determine as orphan file; move it to the
#    trash (cache-like locations) or report it (settings/data locations)
# -----------------------------------------------------------------------------
mac_ops_orphan_app_cleanup() {
  mac_ops_log_info "Orphan app data cleanup started"

  # Stage 1: Collect bundle IDs of installed apps (using global associative array)
  typeset -gA _MAC_OPS_INSTALLED_BUNDLES
  _MAC_OPS_INSTALLED_BUNDLES=()
  typeset -g _MAC_OPS_ORPHAN_APP_MDFIND_APPS=0
  typeset -g _MAC_OPS_ORPHAN_APP_PATHSCAN_APPS=0
  _mac_ops_collect_installed_bundles

  local bundle_count=${#_MAC_OPS_INSTALLED_BUNDLES[@]}
  mac_ops_log_info "${bundle_count} installed app bundle IDs collected"

  if [[ ${bundle_count} -eq 0 ]]; then
    mac_ops_log_warn "Failed to collect installed app bundle IDs. Aborting for safety."
    return 1
  fi

  # "Installed" must not rest on one signal. Spotlight is the only source that
  # sees apps outside the standard directories (JetBrains Toolbox, Setapp,
  # custom paths). When its index is disabled, empty or only partly built, an
  # installed app can look like an orphan, so nothing is moved in this run.
  typeset -g _MAC_OPS_ORPHAN_APP_REPORT_ONLY=false
  local spotlight_problem=""
  if [[ ${_MAC_OPS_ORPHAN_APP_MDFIND_APPS} -eq 0 ]]; then
    spotlight_problem="Spotlight (mdfind) returned no applications"
  elif ! mdutil -s / 2>/dev/null | grep -q "Indexing enabled"; then
    spotlight_problem="Spotlight indexing is not reported as enabled for / (mdutil -s /)"
  elif (( _MAC_OPS_ORPHAN_APP_MDFIND_APPS * 2 < _MAC_OPS_ORPHAN_APP_PATHSCAN_APPS )); then
    spotlight_problem="Spotlight (mdfind) found ${_MAC_OPS_ORPHAN_APP_MDFIND_APPS} app bundle IDs, less than half of the ${_MAC_OPS_ORPHAN_APP_PATHSCAN_APPS} found in the app directories (index incomplete)"
  fi
  if [[ -n "${spotlight_problem}" ]]; then
    _MAC_OPS_ORPHAN_APP_REPORT_ONLY=true
    mac_ops_log_warn "Orphan app cleanup: ${spotlight_problem}, installed-app detection is incomplete. This run is report-only, nothing will be moved."
  fi

  # Stage 1.5: Collect running app bundle IDs for additional protection
  typeset -gA _MAC_OPS_RUNNING_BUNDLES
  _MAC_OPS_RUNNING_BUNDLES=()
  # When the list cannot be built (lsappinfo missing, failing, or listing no
  # app at all, which never happens in a GUI session), every entry is treated
  # as belonging to a running app and skipped.
  typeset -g _MAC_OPS_ORPHAN_APP_RUNNING_UNKNOWN=false
  local _running_id _lsapp_out="" _lsapp_rc=0
  _lsapp_out=$(_mac_ops_running_bundle_ids)
  _lsapp_rc=$?
  while IFS= read -r _running_id; do
    [[ -n "${_running_id}" ]] && _MAC_OPS_RUNNING_BUNDLES[${_running_id}]=1
  done < <(print -r -- "${_lsapp_out}" | sort -u)
  if [[ ${_lsapp_rc} -ne 0 || ${#_MAC_OPS_RUNNING_BUNDLES[@]} -eq 0 ]]; then
    _MAC_OPS_ORPHAN_APP_RUNNING_UNKNOWN=true
    mac_ops_log_warn "Orphan app cleanup: running-app list unavailable (lsappinfo failed or listed no app), every entry is treated as in use and skipped"
  fi
  mac_ops_log_debug "Running apps: ${#_MAC_OPS_RUNNING_BUNDLES[@]} bundles protected"

  # Stage 2: Search for orphan data in each scan target path
  local total_cleaned=0
  for scan_dir in "${MAC_OPS_ORPHAN_APP_SCAN_DIRS[@]}"; do
    if [[ ! -d "${scan_dir}" ]]; then
      mac_ops_log_debug "Scan target path not found: ${scan_dir}"
      continue
    fi

    # Process Preferences directory based on plist files
    if [[ "${scan_dir}" == *"/Preferences" ]]; then
      _mac_ops_scan_preferences "${scan_dir}"
    else
      _mac_ops_scan_directory "${scan_dir}"
    fi
  done

  # Cleanup global variables
  unset _MAC_OPS_INSTALLED_BUNDLES
  unset _MAC_OPS_RUNNING_BUNDLES
  unset _MAC_OPS_ORPHAN_APP_RUNNING_UNKNOWN
  unset _MAC_OPS_ORPHAN_APP_REPORT_ONLY
  unset _MAC_OPS_ORPHAN_APP_MDFIND_APPS
  unset _MAC_OPS_ORPHAN_APP_PATHSCAN_APPS
  unset _MAC_OPS_INSTALLED_VENDORS

  mac_ops_log_info "Orphan app data cleanup completed"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Print the CFBundleIdentifier of a bundle (.app, .xpc, .appex).
# Prints nothing if the bundle has no readable Info.plist or no identifier.
# Usage: _mac_ops_orphan_app_read_bundle_id <bundle_path>
# -----------------------------------------------------------------------------
_mac_ops_orphan_app_read_bundle_id() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  local info_plist="${1}/Contents/Info.plist"
  [[ -f "${info_plist}" ]] || info_plist="${1}/Info.plist"
  [[ -f "${info_plist}" ]] || return 0
  /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${info_plist}" 2>/dev/null || true
}

# How deep below <app>/Contents nested bundles are searched for. Depth 6 covers
# Contents/Frameworks/X.framework/Versions/A/Helpers/Y.app.
typeset -g _MAC_OPS_ORPHAN_APP_NESTED_DEPTH=6

# -----------------------------------------------------------------------------
# Internal: Collect the bundle IDs of bundles nested inside an installed app:
# login items (Contents/Library/LoginItems/*.app), helpers (Contents/Helpers),
# Electron helpers (Contents/Frameworks/*.app), XPC services
# (Contents/XPCServices/*.xpc), extensions (Contents/PlugIns/*.appex) and any
# other .app/.xpc/.appex within _MAC_OPS_ORPHAN_APP_NESTED_DEPTH levels.
# These bundles keep their own data under ~/Library and are not reported by
# Spotlight or by the shallow scan of the app directories.
# Sets REPLY to the number of new IDs added (no output, so the caller must not
# run it in a command substitution, which would lose the additions).
# Usage: _mac_ops_collect_nested_bundles <app_path>
# -----------------------------------------------------------------------------
_mac_ops_collect_nested_bundles() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  local app_path="${1}"
  local added=0
  local nested_path nested_id
  REPLY=0
  [[ -d "${app_path}/Contents" ]] || return 0
  while IFS= read -r nested_path; do
    nested_id=$(_mac_ops_orphan_app_read_bundle_id "${nested_path}")
    if [[ -n "${nested_id}" && -z "${_MAC_OPS_INSTALLED_BUNDLES[${nested_id}]+_}" ]]; then
      _MAC_OPS_INSTALLED_BUNDLES[${nested_id}]=1
      added=$(( added + 1 ))
      mac_ops_log_debug "Bundle ID collected (nested in ${app_path:t}): ${nested_id}"
    fi
  done < <(find "${app_path}/Contents" -maxdepth "${_MAC_OPS_ORPHAN_APP_NESTED_DEPTH}" \
    \( -name "*.app" -o -name "*.xpc" -o -name "*.appex" \) -type d 2>/dev/null)
  REPLY=${added}
}

# -----------------------------------------------------------------------------
# Internal: Collect bundle IDs of installed apps into associative array
# Stage A: standard app directories (/Applications, ~/Applications, /System/Applications)
# Stage B: mdfind (Spotlight) — JetBrains Toolbox, Whale, Setapp, mas, custom paths
# Stage C: Homebrew Cask — /opt/homebrew/Caskroom (NOT indexed by Spotlight)
# Stage D: LaunchDaemons/LaunchAgents — services like Korean banking security software
# Stage E: bundles nested inside every app found in A-C (login items, helpers,
#          XPC services, extensions)
# Sets _MAC_OPS_ORPHAN_APP_PATHSCAN_APPS (distinct IDs from Stage A) and
# _MAC_OPS_ORPHAN_APP_MDFIND_APPS (distinct IDs Spotlight returned).
# -----------------------------------------------------------------------------
_mac_ops_collect_installed_bundles() {
  # Prevent ERR_EXIT from aborting the scan mid-way (PlistBuddy exits 1 even on success)
  setopt LOCAL_OPTIONS NO_ERR_EXIT

  local bundle_id=""
  # Top-level app bundles found by stages A-C, scanned for nested bundles in E
  local -A top_level_apps
  top_level_apps=()

  # Stage A: scan standard app directories (fast, covers most cases)
  local app_dirs=("/Applications" "${HOME}/Applications" "/System/Applications")
  local app_base app_path
  local -A pathscan_ids
  pathscan_ids=()
  for app_base in "${app_dirs[@]}"; do
    [[ ! -d "${app_base}" ]] && continue
    while IFS= read -r app_path; do
      [[ ! -d "${app_path}" ]] && continue
      bundle_id=$(_mac_ops_orphan_app_read_bundle_id "${app_path}")
      if [[ -n "${bundle_id}" ]]; then
        _MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]=1
        pathscan_ids[${bundle_id}]=1
        [[ "${app_path}" != *.app/* ]] && top_level_apps[${app_path}]=1
        mac_ops_log_debug "Bundle ID collected (path): ${bundle_id}"
      fi
    done < <(find "${app_base}" -maxdepth 3 -name "*.app" -type d 2>/dev/null)
  done
  _MAC_OPS_ORPHAN_APP_PATHSCAN_APPS=${#pathscan_ids[@]}

  # Stage B: mdfind — catches ALL Spotlight-indexed apps regardless of install location
  # (JetBrains Toolbox, Whale, Setapp, mas, custom paths, etc.)
  local mdfind_count=0
  local -A mdfind_ids
  mdfind_ids=()
  while IFS= read -r app_path; do
    [[ ! -d "${app_path}" ]] && continue
    bundle_id=$(_mac_ops_orphan_app_read_bundle_id "${app_path}")
    [[ -z "${bundle_id}" ]] && continue
    # Count every distinct ID Spotlight returned, including the ones Stage A
    # already found: the count is compared with Stage A to judge the index.
    mdfind_ids[${bundle_id}]=1
    [[ "${app_path}" != *.app/* ]] && top_level_apps[${app_path}]=1
    if [[ -z "${_MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]+_}" ]]; then
      _MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]=1
      mdfind_count=$(( mdfind_count + 1 ))
      mac_ops_log_debug "Bundle ID collected (mdfind): ${bundle_id}"
    fi
  done < <(mdfind "kMDItemContentTypeTree == 'com.apple.application-bundle'" 2>/dev/null)
  _MAC_OPS_ORPHAN_APP_MDFIND_APPS=${#mdfind_ids[@]}
  mac_ops_log_debug "mdfind added ${mdfind_count} additional bundle IDs (${_MAC_OPS_ORPHAN_APP_MDFIND_APPS} distinct, path scan ${_MAC_OPS_ORPHAN_APP_PATHSCAN_APPS})"

  # Stage C: Homebrew Cask — apps installed via brew are NOT indexed by Spotlight
  # Covers: Arc, Warp, TablePlus, Proxyman, Raycast installed via brew cask, etc.
  local brew_cask_count=0
  local cask_base
  for cask_base in "/opt/homebrew/Caskroom" "/usr/local/Caskroom"; do
    [[ ! -d "${cask_base}" ]] && continue
    while IFS= read -r app_path; do
      [[ ! -d "${app_path}" ]] && continue
      bundle_id=$(_mac_ops_orphan_app_read_bundle_id "${app_path}")
      [[ -z "${bundle_id}" ]] && continue
      [[ "${app_path}" != *.app/* ]] && top_level_apps[${app_path}]=1
      if [[ -z "${_MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]+_}" ]]; then
        _MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]=1
        brew_cask_count=$(( brew_cask_count + 1 ))
        mac_ops_log_debug "Bundle ID collected (brew-cask): ${bundle_id}"
      fi
    done < <(find "${cask_base}" -maxdepth 4 -name "*.app" -type d 2>/dev/null)
  done
  mac_ops_log_debug "Homebrew Cask added ${brew_cask_count} additional bundle IDs"

  # Stage D: LaunchDaemons/LaunchAgents — system services not packaged as .app bundles
  # Covers: Korean banking security (AhnLab V3, TouchEN nxKey, INISAFE CrossWeb EX, etc.)
  local launch_count=0
  local launch_dir plist_path launch_label
  for launch_dir in \
    "/Library/LaunchDaemons" \
    "/Library/LaunchAgents" \
    "${HOME}/Library/LaunchAgents"; do
    [[ ! -d "${launch_dir}" ]] && continue
    while IFS= read -r plist_path; do
      launch_label=$(/usr/libexec/PlistBuddy -c 'Print Label' "${plist_path}" 2>/dev/null || true)
      if [[ -n "${launch_label}" && -z "${_MAC_OPS_INSTALLED_BUNDLES[${launch_label}]+_}" ]]; then
        _MAC_OPS_INSTALLED_BUNDLES[${launch_label}]=1
        launch_count=$(( launch_count + 1 ))
        mac_ops_log_debug "Bundle ID collected (launchd): ${launch_label}"
      fi
    done < <(find "${launch_dir}" -maxdepth 1 -name "*.plist" -type f 2>/dev/null)
  done
  mac_ops_log_debug "LaunchDaemons/Agents added ${launch_count} additional bundle IDs"

  # Stage E: bundles nested inside installed apps. Apple's own apps are skipped:
  # their data is com.apple.* and never scanned.
  local nested_count=0 REPLY
  for app_path in "${(@k)top_level_apps}"; do
    [[ "${app_path}" == /System/* ]] && continue
    _mac_ops_collect_nested_bundles "${app_path}"
    nested_count=$(( nested_count + ${REPLY:-0} ))
  done
  mac_ops_log_debug "Nested bundles added ${nested_count} additional bundle IDs"
}

# -----------------------------------------------------------------------------
# Internal: Compute the grace period cutoff once per scan
# Sets _MAC_OPS_ORPHAN_APP_CUTOFF_EPOCH and _MAC_OPS_ORPHAN_APP_CUTOFF_STAMP.
# The stamp is an absolute local time ("2026-01-31 09:00:00") because find
# implementations disagree on relative dates such as "7 days ago".
# Returns 1 if the cutoff cannot be computed (callers must then scan nothing).
# -----------------------------------------------------------------------------
_mac_ops_orphan_app_prepare_cutoff() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT

  typeset -g _MAC_OPS_ORPHAN_APP_CUTOFF_EPOCH=""
  typeset -g _MAC_OPS_ORPHAN_APP_CUTOFF_STAMP=""

  if [[ ! "${MAC_OPS_ORPHAN_APP_GRACE_DAYS}" =~ ^[0-9]+$ ]]; then
    mac_ops_log_warn "Orphan app scan skipped: MAC_OPS_ORPHAN_APP_GRACE_DAYS is not a number (${MAC_OPS_ORPHAN_APP_GRACE_DAYS})"
    return 1
  fi

  local cutoff
  cutoff=$(date -v-"${MAC_OPS_ORPHAN_APP_GRACE_DAYS}"d '+%s %Y-%m-%d %H:%M:%S' 2>/dev/null)
  local cutoff_epoch="${cutoff%% *}"
  local cutoff_stamp="${cutoff#* }"

  if [[ ! "${cutoff_epoch}" =~ ^[0-9]+$ || -z "${cutoff_stamp}" || "${cutoff_stamp}" == "${cutoff}" ]]; then
    mac_ops_log_warn "Orphan app scan skipped: cannot compute the grace period cutoff"
    return 1
  fi

  _MAC_OPS_ORPHAN_APP_CUTOFF_EPOCH="${cutoff_epoch}"
  _MAC_OPS_ORPHAN_APP_CUTOFF_STAMP="${cutoff_stamp}"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Check that nothing inside an entry was modified after the cutoff
# The modification time of a directory does not change when a file deep inside
# it changes, so an old directory can still hold a profile that is in use.
# The search is bounded to _MAC_OPS_ORPHAN_APP_RECENT_DEPTH levels so a large
# old tree is not walked in full; a recent file deeper than that is not seen,
# and the log line of every orphan says so.
# Returns 0 only when the search ran successfully and found no recent file.
# A failed search (unreadable subdirectory, unsupported option) or a missing
# cutoff timestamp returns 1, so the caller leaves the entry alone.
# Usage: _mac_ops_orphan_app_has_no_recent_file <path>
# -----------------------------------------------------------------------------
typeset -g _MAC_OPS_ORPHAN_APP_RECENT_DEPTH=6

_mac_ops_orphan_app_has_no_recent_file() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT

  local target_path="${1}"
  local find_output
  local find_status=0

  # find -newermt "" succeeds and compares against an arbitrary time, which
  # would read as "no recent file"
  if [[ -z "${_MAC_OPS_ORPHAN_APP_CUTOFF_STAMP}" ]]; then
    mac_ops_log_warn "Orphan check inconclusive, left untouched: ${target_path} (no grace period cutoff timestamp)"
    return 1
  fi

  find_output=$(find "${target_path}" -maxdepth "${_MAC_OPS_ORPHAN_APP_RECENT_DEPTH}" -type f -newermt "${_MAC_OPS_ORPHAN_APP_CUTOFF_STAMP}" -print -quit 2>&1) || find_status=$?

  if [[ ${find_status} -ne 0 ]]; then
    mac_ops_log_warn "Orphan check inconclusive, left untouched: ${target_path} (recent-file search failed with exit ${find_status}: ${find_output%%$'\n'*})"
    return 1
  fi

  if [[ -n "${find_output}" ]]; then
    mac_ops_log_debug "Recently modified file inside, skipped: ${find_output}"
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Internal: Decide what happens to one entry whose name is a bundle ID
# The entry is moved or reported only if it passes every check below. Each
# check that fails leaves the entry untouched.
# Sets _MAC_OPS_ORPHAN_APP_RESULT to "moved", "reported" or "skipped" and
# always returns 0.
# Usage: _mac_ops_orphan_app_process_entry <path> <bundle_id_name> <scan_dir> <kind>
#   kind: "data" (directory entry) or "preference" (plist file in Preferences)
# -----------------------------------------------------------------------------
_mac_ops_orphan_app_process_entry() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT

  local item="${1}"
  local item_name="${2}"
  local scan_dir="${3}"
  local kind="${4}"
  local label="app data"
  local trash_reason="orphan-app-data"

  if [[ "${kind}" == "preference" ]]; then
    label="Preference"
    trash_reason="orphan-app-preference"
  fi

  typeset -g _MAC_OPS_ORPHAN_APP_RESULT="skipped"

  # Bundle ID pattern matching (com.xxx.xxx or org.xxx.xxx, etc.)
  # Reverse domain format with at least 2 dots (.)
  if ! _mac_ops_is_bundle_id_name "${item_name}"; then
    return 0
  fi

  # A symbolic link's own age says nothing about the data it points to
  if [[ -L "${item}" ]]; then
    mac_ops_log_debug "Symbolic link, skipped: ${item}"
    return 0
  fi

  # Exclude com.apple.* (system data)
  if [[ "${item_name}" == com.apple.* ]]; then
    return 0
  fi

  # Exclude macOS system group container patterns
  if [[ "${item_name}" == systemgroup.* || "${item_name}" == group.* ]]; then
    return 0
  fi

  # Don't process Group Containers subdirectories (can be shared by multiple apps)
  if [[ "${scan_dir}" == *"Group Containers"* ]]; then
    return 0
  fi

  # Safety safelist check (second line of defense)
  if _mac_ops_is_safelisted "${item_name}"; then
    mac_ops_log_debug "Safelist protected: ${item_name}"
    return 0
  fi

  # Security software is never touched, whatever its bundle ID prefix is
  if _mac_ops_fc_is_security_path "${item_name}"; then
    mac_ops_log_debug "Security software keyword protected: ${item_name}"
    return 0
  fi

  # User ignore rules: bundle ID pattern
  if mac_ops_ignore_check_bundle "${item_name}"; then
    mac_ops_log_debug "User ignore (bundle): ${item_name}"
    return 0
  fi

  # User ignore rules: path pattern
  if mac_ops_ignore_check_path "${item}"; then
    mac_ops_log_debug "User ignore (path): ${item}"
    return 0
  fi

  # Skip if in installed apps list (exact or prefix match — protects helper bundle IDs
  # like com.google.Chrome.helper when com.google.Chrome is installed)
  local _inst_id
  for _inst_id in "${(@k)_MAC_OPS_INSTALLED_BUNDLES}"; do
    if [[ "${item_name}" == "${_inst_id}" || "${item_name}" == "${_inst_id}."* ]]; then
      return 0
    fi
  done

  # Skip if an installed bundle ID has the same vendor (first two labels):
  # an installed app's helpers and services are not always detected
  local _vendor
  _vendor=$(_mac_ops_orphan_app_vendor "${item_name}")
  if [[ -n "${_vendor}" && -n "${_MAC_OPS_INSTALLED_VENDORS[${_vendor}]+_}" ]]; then
    mac_ops_log_debug "Same vendor as an installed app (${_vendor}), protected: ${item_name}"
    return 0
  fi

  # Skip if app is currently running
  if [[ -n "${_MAC_OPS_RUNNING_BUNDLES[${item_name}]+_}" ]]; then
    mac_ops_log_debug "Running app data protected: ${item_name}"
    return 0
  fi
  if [[ "${_MAC_OPS_ORPHAN_APP_RUNNING_UNKNOWN:-false}" != "false" ]]; then
    mac_ops_log_debug "Protected, skipped (orphan-app-cleanup): ${item} (reason: running-app list unavailable)"
    return 0
  fi

  # Grace period, part 1: the entry itself. An unreadable modification time
  # is not evidence of age, so the entry is left alone.
  local mtime
  mtime=$(stat -f%m "${item}" 2>/dev/null)
  if [[ ! "${mtime}" =~ ^[0-9]+$ ]]; then
    mac_ops_log_warn "Orphan check inconclusive, left untouched: ${item} (cannot read modification time)"
    return 0
  fi
  if [[ ${mtime} -ge ${_MAC_OPS_ORPHAN_APP_CUTOFF_EPOCH} ]]; then
    mac_ops_log_debug "Recently modified, skipped: ${item_name}"
    return 0
  fi

  # Safety check. Preferences is in the whitelist as a whole, so the check
  # would block every plist file in it; preference files skip it.
  if [[ "${kind}" != "preference" ]]; then
    if ! mac_ops_is_path_safe "${item}"; then
      return 0
    fi
  fi

  # Grace period, part 2: any file inside the entry
  if ! _mac_ops_orphan_app_has_no_recent_file "${item}"; then
    return 0
  fi

  # Every check passed: this is an orphan. Say why before acting on it.
  local item_size age_days
  item_size=$(mac_ops_get_dir_size "${item}")
  age_days=$(( ($(date +%s) - mtime) / 86400 ))

  mac_ops_log_info "Orphan ${label} found: ${item_name} ($(mac_ops_format_bytes "${item_size}")) in ${scan_dir} - checks passed: not installed, not running, not safelisted, older than ${MAC_OPS_ORPHAN_APP_GRACE_DAYS} days (last modified ${age_days} days ago), no file inside modified since ${_MAC_OPS_ORPHAN_APP_CUTOFF_STAMP} (searched ${_MAC_OPS_ORPHAN_APP_RECENT_DEPTH} levels deep, a newer file deeper down would not be seen), no installed app from vendor ${_vendor}"

  # Report instead of moving when the run is report-only, or when the entry is
  # settings/data and the user did not opt in to moving it.
  local report_reason=""
  if [[ "${_MAC_OPS_ORPHAN_APP_REPORT_ONLY:-true}" != "false" ]]; then
    report_reason="report-only run, installed-app detection is incomplete"
  elif ! _mac_ops_orphan_app_is_cache_location "${scan_dir}" && [[ "${MAC_OPS_ORPHAN_APP_DATA_ACTION}" != "trash" ]]; then
    report_reason="settings/data location, set MAC_OPS_ORPHAN_APP_DATA_ACTION=trash to move"
  fi

  if [[ -n "${report_reason}" ]]; then
    mac_ops_log_info "Orphan ${label} reported, not moved: ${item} (${report_reason})"
    _MAC_OPS_ORPHAN_APP_RESULT="reported"
    return 0
  fi

  # Size guard check
  if ! mac_ops_check_size_guard "${item}"; then
    return 0
  fi

  # Move to trash
  if mac_ops_trash_move "${item}" "${trash_reason}" "orphan-app-cleanup"; then
    MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
    MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + item_size))
    _MAC_OPS_ORPHAN_APP_RESULT="moved"
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Internal: Search and cleanup orphan bundle ID entries in directory
# Process directories whose name matches bundle ID pattern (com.xxx.xxx) but not in installed list
# Usage: _mac_ops_scan_directory <scan_path>
# -----------------------------------------------------------------------------
_mac_ops_scan_directory() {
  local scan_dir="${1}"
  local count=0
  local reported=0
  local item item_name

  mac_ops_log_info "Orphan data scan: ${scan_dir}"

  if ! _mac_ops_orphan_app_prepare_cutoff; then
    return 0
  fi
  _mac_ops_orphan_app_build_vendor_index

  # Iterate only 1st level subitems (bundle ID directories)
  for item in "${scan_dir}"/*(N); do
    item_name=$(basename "${item}")

    _mac_ops_orphan_app_process_entry "${item}" "${item_name}" "${scan_dir}" "data"

    if [[ "${_MAC_OPS_ORPHAN_APP_RESULT}" == "moved" ]]; then
      count=$((count + 1))
    elif [[ "${_MAC_OPS_ORPHAN_APP_RESULT}" == "reported" ]]; then
      reported=$((reported + 1))
    fi
  done

  mac_ops_log_info "${scan_dir}: ${count} orphan items cleaned, ${reported} reported only"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Search and cleanup orphan plist files in ~/Library/Preferences
# Extract bundle ID from *.plist filename and match
# Usage: _mac_ops_scan_preferences <Preferences_path>
# -----------------------------------------------------------------------------
_mac_ops_scan_preferences() {
  local pref_dir="${1}"
  local count=0
  local reported=0
  local plist_file file_name

  mac_ops_log_info "Orphan Preferences scan: ${pref_dir}"

  if ! _mac_ops_orphan_app_prepare_cutoff; then
    return 0
  fi
  _mac_ops_orphan_app_build_vendor_index

  # shellcheck disable=SC1036,SC1058,SC1072,SC1073
  for plist_file in "${pref_dir}"/*.plist(N); do
    [[ ! -f "${plist_file}" ]] && continue

    # Extract bundle ID from filename (com.xxx.xxx.plist -> com.xxx.xxx)
    file_name=$(basename "${plist_file}" .plist)

    _mac_ops_orphan_app_process_entry "${plist_file}" "${file_name}" "${pref_dir}" "preference"

    if [[ "${_MAC_OPS_ORPHAN_APP_RESULT}" == "moved" ]]; then
      count=$((count + 1))
    elif [[ "${_MAC_OPS_ORPHAN_APP_RESULT}" == "reported" ]]; then
      reported=$((reported + 1))
    fi
  done

  mac_ops_log_info "${pref_dir}: ${count} orphan Preferences cleaned, ${reported} reported only"
  return 0
}
