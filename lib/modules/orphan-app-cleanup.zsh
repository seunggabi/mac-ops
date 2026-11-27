# =============================================================================
# mac-ops: Orphan app data cleanup module
# Detect and cleanup leftover files from deleted apps (Application Support, Caches, Preferences, etc.)
# Excludes com.apple.*, Group Containers, systemgroup.*, security software, and
# entries that were modified (or hold a file modified) within the grace period
#
# Settings and data are not cache: an orphan in a data-bearing location
# (Application Support, Preferences, Containers) is only reported unless the
# user opts in with MAC_OPS_ORPHAN_APP_DATA_ACTION=trash.
# =============================================================================

# --- Default settings ---
MAC_OPS_ORPHAN_APP_GRACE_DAYS=${MAC_OPS_ORPHAN_APP_GRACE_DAYS:-7}

# What to do with an orphan found in a settings/data location:
#   report (default) - log it with its size and the checks it passed, move nothing
#   trash            - move it to the mac-ops trash like a cache orphan
# Any other value behaves like "report".
MAC_OPS_ORPHAN_APP_DATA_ACTION=${MAC_OPS_ORPHAN_APP_DATA_ACTION:-report}

# --- Cache-like locations (matched by directory name) ---
# An orphan here can be rebuilt by its app, so it is moved to the trash.
# Every scan location that is NOT listed here is treated as settings/data.
_MAC_OPS_ORPHAN_APP_CACHE_DIR_NAMES=(
  "Caches"
  "HTTPStorages"
  "Saved Application State"
  "WebKit"
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

# -----------------------------------------------------------------------------
# Security software safelist: keywords matched case-insensitively anywhere in
# the entry name. Endpoint security, VPN and Korean banking security products
# use many bundle ID prefixes, and removing their data can break logins or
# trigger a reinstall, so they are never touched.
# -----------------------------------------------------------------------------
_MAC_OPS_SECURITY_KEYWORD_SAFELIST=(
  "ahnlab"
  "astx"
  "crossex"
  "delfino"
  "forticlient"
  "fortinet"
  "iniline"
  "inisafe"
  "initech"
  "jiran"
  "jkok"
  "nprotect"
  "pcassist"
  "pnpsecure"
  "raon"
  "touchen"
  "veraport"
  "wizvera"
)

# -----------------------------------------------------------------------------
# Internal: Check if a name contains a security software keyword
# Returns 0 (true) if protected, 1 (false) if not
# Usage: _mac_ops_is_security_keyword_name <name>
# -----------------------------------------------------------------------------
_mac_ops_is_security_keyword_name() {
  local lower_name="${(L)1}"
  local keyword
  for keyword in "${_MAC_OPS_SECURITY_KEYWORD_SAFELIST[@]}"; do
    if [[ "${lower_name}" == *"${keyword}"* ]]; then
      return 0
    fi
  done
  return 1
}

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
  _mac_ops_collect_installed_bundles

  local bundle_count=${#_MAC_OPS_INSTALLED_BUNDLES[@]}
  mac_ops_log_info "${bundle_count} installed app bundle IDs collected"

  if [[ ${bundle_count} -eq 0 ]]; then
    mac_ops_log_warn "Failed to collect installed app bundle IDs. Aborting for safety."
    return 1
  fi

  # "Installed" must not rest on one signal. Spotlight is the only source that
  # sees apps outside the standard directories (JetBrains Toolbox, Setapp,
  # custom paths). When it returns no application at all, its index is broken
  # or disabled and an installed app can look like an orphan, so nothing is
  # moved in this run.
  typeset -g _MAC_OPS_ORPHAN_APP_REPORT_ONLY=false
  if [[ ${_MAC_OPS_ORPHAN_APP_MDFIND_APPS} -eq 0 ]]; then
    _MAC_OPS_ORPHAN_APP_REPORT_ONLY=true
    mac_ops_log_warn "Orphan app cleanup: Spotlight (mdfind) returned no applications, installed-app detection is incomplete. This run is report-only, nothing will be moved."
  fi

  # Stage 1.5: Collect running app bundle IDs for additional protection
  typeset -gA _MAC_OPS_RUNNING_BUNDLES
  _MAC_OPS_RUNNING_BUNDLES=()
  local _running_id
  while IFS= read -r _running_id; do
    [[ -n "${_running_id}" ]] && _MAC_OPS_RUNNING_BUNDLES[${_running_id}]=1
  done < <(lsappinfo list 2>/dev/null | grep 'bundleID=' | sed 's/.*bundleID="\([^"]*\)".*/\1/' | grep -v '^\[' | sort -u)
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
  unset _MAC_OPS_ORPHAN_APP_REPORT_ONLY
  unset _MAC_OPS_ORPHAN_APP_MDFIND_APPS

  mac_ops_log_info "Orphan app data cleanup completed"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Collect bundle IDs of installed apps into associative array
# Stage A: standard app directories (/Applications, ~/Applications, /System/Applications)
# Stage B: mdfind (Spotlight) — JetBrains Toolbox, Whale, Setapp, mas, custom paths
# Stage C: Homebrew Cask — /opt/homebrew/Caskroom (NOT indexed by Spotlight)
# Stage D: LaunchDaemons/LaunchAgents — services like Korean banking security software
# -----------------------------------------------------------------------------
_mac_ops_collect_installed_bundles() {
  # Prevent ERR_EXIT from aborting the scan mid-way (PlistBuddy exits 1 even on success)
  setopt LOCAL_OPTIONS NO_ERR_EXIT

  local info_plist=""
  local bundle_id=""

  # Stage A: scan standard app directories (fast, covers most cases)
  local app_dirs=("/Applications" "${HOME}/Applications" "/System/Applications")
  local app_base app_path
  for app_base in "${app_dirs[@]}"; do
    [[ ! -d "${app_base}" ]] && continue
    while IFS= read -r app_path; do
      [[ ! -d "${app_path}" ]] && continue
      info_plist="${app_path}/Contents/Info.plist"
      [[ ! -f "${info_plist}" ]] && continue
      bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${info_plist}" 2>/dev/null || true)
      if [[ -n "${bundle_id}" ]]; then
        _MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]=1
        mac_ops_log_debug "Bundle ID collected (path): ${bundle_id}"
      fi
    done < <(find "${app_base}" -maxdepth 3 -name "*.app" -type d 2>/dev/null)
  done

  # Stage B: mdfind — catches ALL Spotlight-indexed apps regardless of install location
  # (JetBrains Toolbox, Whale, Setapp, mas, custom paths, etc.)
  local mdfind_count=0
  while IFS= read -r app_path; do
    [[ ! -d "${app_path}" ]] && continue
    info_plist="${app_path}/Contents/Info.plist"
    [[ ! -f "${info_plist}" ]] && continue
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${info_plist}" 2>/dev/null || true)
    # Count every application Spotlight returned, including the ones Stage A
    # already found: zero means Spotlight itself is not working.
    if [[ -n "${bundle_id}" ]]; then
      _MAC_OPS_ORPHAN_APP_MDFIND_APPS=$(( ${_MAC_OPS_ORPHAN_APP_MDFIND_APPS:-0} + 1 ))
    fi
    if [[ -n "${bundle_id}" && -z "${_MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]+_}" ]]; then
      _MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]=1
      mdfind_count=$(( mdfind_count + 1 ))
      mac_ops_log_debug "Bundle ID collected (mdfind): ${bundle_id}"
    fi
  done < <(mdfind "kMDItemContentTypeTree == 'com.apple.application-bundle'" 2>/dev/null)
  mac_ops_log_debug "mdfind added ${mdfind_count} additional bundle IDs"

  # Stage C: Homebrew Cask — apps installed via brew are NOT indexed by Spotlight
  # Covers: Arc, Warp, TablePlus, Proxyman, Raycast installed via brew cask, etc.
  local brew_cask_count=0
  local cask_base
  for cask_base in "/opt/homebrew/Caskroom" "/usr/local/Caskroom"; do
    [[ ! -d "${cask_base}" ]] && continue
    while IFS= read -r app_path; do
      [[ ! -d "${app_path}" ]] && continue
      info_plist="${app_path}/Contents/Info.plist"
      [[ ! -f "${info_plist}" ]] && continue
      bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "${info_plist}" 2>/dev/null || true)
      if [[ -n "${bundle_id}" && -z "${_MAC_OPS_INSTALLED_BUNDLES[${bundle_id}]+_}" ]]; then
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
# Returns 0 only when the search ran successfully and found no recent file.
# A failed search (unreadable subdirectory, unsupported option) returns 1, so
# the caller leaves the entry alone.
# Usage: _mac_ops_orphan_app_has_no_recent_file <path>
# -----------------------------------------------------------------------------
_mac_ops_orphan_app_has_no_recent_file() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT

  local target_path="${1}"
  local find_output
  local find_status=0

  find_output=$(find "${target_path}" -type f -newermt "${_MAC_OPS_ORPHAN_APP_CUTOFF_STAMP}" -print -quit 2>&1) || find_status=$?

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
  if _mac_ops_is_security_keyword_name "${item_name}"; then
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

  # Skip if app is currently running
  if [[ -n "${_MAC_OPS_RUNNING_BUNDLES[${item_name}]+_}" ]]; then
    mac_ops_log_debug "Running app data protected: ${item_name}"
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

  mac_ops_log_info "Orphan ${label} found: ${item_name} ($(mac_ops_format_bytes "${item_size}")) in ${scan_dir} - checks passed: not installed, not running, not safelisted, older than ${MAC_OPS_ORPHAN_APP_GRACE_DAYS} days (last modified ${age_days} days ago), no file inside modified since ${_MAC_OPS_ORPHAN_APP_CUTOFF_STAMP}"

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
