# =============================================================================
# mac-ops: Orphan app data cleanup module
# Detect and cleanup leftover files from deleted apps (Application Support, Caches, Preferences, etc.)
# Excludes com.apple.*, Group Containers, systemgroup.*, files modified within last 7 days
# =============================================================================

# --- Default settings ---
MAC_OPS_ORPHAN_APP_GRACE_DAYS=${MAC_OPS_ORPHAN_APP_GRACE_DAYS:-7}

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
# Orphan app data cleanup main function
# 1. Extract bundle IDs of installed apps from /Applications, ~/Applications,
#    Spotlight (mdfind), Homebrew Cask, and LaunchDaemons/Agents
# 2. Search for bundle ID pattern directories/files in scan target paths
# 3. If not in installed apps list, determine as orphan file and cleanup
# -----------------------------------------------------------------------------
mac_ops_orphan_app_cleanup() {
  mac_ops_log_info "Orphan app data cleanup started"

  # Stage 1: Collect bundle IDs of installed apps (using global associative array)
  typeset -gA _MAC_OPS_INSTALLED_BUNDLES
  _MAC_OPS_INSTALLED_BUNDLES=()
  _mac_ops_collect_installed_bundles

  local bundle_count=${#_MAC_OPS_INSTALLED_BUNDLES[@]}
  mac_ops_log_info "${bundle_count} installed app bundle IDs collected"

  if [[ ${bundle_count} -eq 0 ]]; then
    mac_ops_log_warn "Failed to collect installed app bundle IDs. Aborting for safety."
    return 1
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
# Internal: Search and cleanup orphan bundle ID entries in directory
# Process directories whose name matches bundle ID pattern (com.xxx.xxx) but not in installed list
# Usage: _mac_ops_scan_directory <scan_path>
# -----------------------------------------------------------------------------
_mac_ops_scan_directory() {
  local scan_dir="${1}"
  local now_epoch
  local grace_seconds=$((MAC_OPS_ORPHAN_APP_GRACE_DAYS * 86400))
  local count=0
  local item item_name mtime age_seconds item_size

  now_epoch=$(date +%s)

  mac_ops_log_info "Orphan data scan: ${scan_dir}"

  # Iterate only 1st level subitems (bundle ID directories)
  for item in "${scan_dir}"/*(N); do
    item_name=$(basename "${item}")

    # Bundle ID pattern matching (com.xxx.xxx or org.xxx.xxx, etc.)
    # Reverse domain format with at least 2 dots (.)
    if [[ ! "${item_name}" =~ ^[a-zA-Z][a-zA-Z0-9-]*\.[a-zA-Z][a-zA-Z0-9-]*\..+ ]]; then
      continue
    fi

    # Exclude com.apple.* (system data)
    if [[ "${item_name}" == com.apple.* ]]; then
      continue
    fi

    # Exclude macOS system group container patterns
    if [[ "${item_name}" == systemgroup.* || "${item_name}" == group.* ]]; then
      continue
    fi

    # Don't process Group Containers subdirectories (can be shared by multiple apps)
    if [[ "${scan_dir}" == *"Group Containers"* ]]; then
      continue
    fi

    # Safety safelist check (second line of defense)
    if _mac_ops_is_safelisted "${item_name}"; then
      mac_ops_log_debug "Safelist protected: ${item_name}"
      continue
    fi

    # User ignore rules: bundle ID pattern
    if mac_ops_ignore_check_bundle "${item_name}"; then
      mac_ops_log_debug "User ignore (bundle): ${item_name}"
      continue
    fi

    # User ignore rules: path pattern
    if mac_ops_ignore_check_path "${item}"; then
      mac_ops_log_debug "User ignore (path): ${item}"
      continue
    fi

    # Skip if in installed apps list (exact or prefix match — protects helper bundle IDs
    # like com.google.Chrome.helper when com.google.Chrome is installed)
    local _orphan_match=false
    local _inst_id
    for _inst_id in "${(@k)_MAC_OPS_INSTALLED_BUNDLES}"; do
      if [[ "${item_name}" == "${_inst_id}" || "${item_name}" == "${_inst_id}."* ]]; then
        _orphan_match=true
        break
      fi
    done
    [[ "${_orphan_match}" == "true" ]] && continue

    # Skip if app is currently running
    if [[ -n "${_MAC_OPS_RUNNING_BUNDLES[${item_name}]+_}" ]]; then
      mac_ops_log_debug "Running app data protected: ${item_name}"
      continue
    fi

    # Check recent modification (grace period)
    mtime=$(stat -f%m "${item}" 2>/dev/null)
    if [[ -n "${mtime}" && "${mtime}" =~ ^[0-9]+$ ]]; then
      age_seconds=$((now_epoch - mtime))
      if [[ ${age_seconds} -lt ${grace_seconds} ]]; then
        mac_ops_log_debug "Recently modified, skipped: ${item_name} (${age_seconds} seconds ago)"
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

    # Record file/directory size
    item_size=$(mac_ops_get_dir_size "${item}")

    mac_ops_log_info "Orphan app data found: ${item_name} ($(mac_ops_format_bytes "${item_size}"))"

    # Move to trash
    if mac_ops_trash_move "${item}" "orphan-app-data" "orphan-app-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + item_size))
      count=$((count + 1))
    fi
  done

  mac_ops_log_info "${scan_dir}: ${count} orphan items cleaned"
  return 0
}

# -----------------------------------------------------------------------------
# Internal: Search and cleanup orphan plist files in ~/Library/Preferences
# Extract bundle ID from *.plist filename and match
# Usage: _mac_ops_scan_preferences <Preferences_path>
# -----------------------------------------------------------------------------
_mac_ops_scan_preferences() {
  local pref_dir="${1}"
  local now_epoch
  local grace_seconds=$((MAC_OPS_ORPHAN_APP_GRACE_DAYS * 86400))
  local count=0
  local plist_file file_name mtime age_seconds file_size

  now_epoch=$(date +%s)

  mac_ops_log_info "Orphan Preferences scan: ${pref_dir}"

  # shellcheck disable=SC1036,SC1058,SC1072,SC1073
  for plist_file in "${pref_dir}"/*.plist(N); do
    [[ ! -f "${plist_file}" ]] && continue

    # Extract bundle ID from filename (com.xxx.xxx.plist -> com.xxx.xxx)
    file_name=$(basename "${plist_file}" .plist)

    # Bundle ID pattern matching
    if [[ ! "${file_name}" =~ ^[a-zA-Z][a-zA-Z0-9-]*\.[a-zA-Z][a-zA-Z0-9-]*\..+ ]]; then
      continue
    fi

    # Exclude com.apple.*
    if [[ "${file_name}" == com.apple.* ]]; then
      continue
    fi

    # Exclude macOS system group container patterns
    if [[ "${file_name}" == systemgroup.* || "${file_name}" == group.* ]]; then
      continue
    fi

    # Safety safelist check (second line of defense)
    if _mac_ops_is_safelisted "${file_name}"; then
      mac_ops_log_debug "Safelist protected (pref): ${file_name}"
      continue
    fi

    # User ignore rules: bundle ID pattern
    if mac_ops_ignore_check_bundle "${file_name}"; then
      mac_ops_log_debug "User ignore (bundle/pref): ${file_name}"
      continue
    fi

    # Skip if in installed apps list (exact or prefix match for helper bundle IDs)
    local _pref_match=false
    local _pref_inst_id
    for _pref_inst_id in "${(@k)_MAC_OPS_INSTALLED_BUNDLES}"; do
      if [[ "${file_name}" == "${_pref_inst_id}" || "${file_name}" == "${_pref_inst_id}."* ]]; then
        _pref_match=true
        break
      fi
    done
    [[ "${_pref_match}" == "true" ]] && continue

    # Skip if app is currently running
    if [[ -n "${_MAC_OPS_RUNNING_BUNDLES[${file_name}]+_}" ]]; then
      mac_ops_log_debug "Running app preference protected: ${file_name}"
      continue
    fi

    # Check recent modification
    mtime=$(stat -f%m "${plist_file}" 2>/dev/null)
    if [[ -n "${mtime}" && "${mtime}" =~ ^[0-9]+$ ]]; then
      age_seconds=$((now_epoch - mtime))
      if [[ ${age_seconds} -lt ${grace_seconds} ]]; then
        continue
      fi
    fi

    # Safety check -- Preferences is in whitelist so
    # individual plist files are safe (parent directory itself is protected)
    # is_path_safe protects parent directory ~/Library/Preferences so
    # direct call on subfiles will block -> skip here for individual files
    # Check only size guard instead
    if ! mac_ops_check_size_guard "${plist_file}"; then
      continue
    fi

    # Record file size
    file_size=$(mac_ops_get_dir_size "${plist_file}")

    mac_ops_log_info "Orphan Preference found: ${file_name}.plist ($(mac_ops_format_bytes "${file_size}"))"

    # Move to trash
    if mac_ops_trash_move "${plist_file}" "orphan-app-preference" "orphan-app-cleanup"; then
      MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
      MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
      count=$((count + 1))
    fi
  done

  mac_ops_log_info "${pref_dir}: ${count} orphan Preferences cleaned"
  return 0
}
