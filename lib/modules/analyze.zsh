# =============================================================================
# mac-ops: Disk space analysis module
# Analyze current size of each cleanup target path and output report
# =============================================================================

# -----------------------------------------------------------------------------
# Disk space analysis report
# Check current size of each cleanup target path and show reclaimable space
# -----------------------------------------------------------------------------
mac_ops_analyze() {
  setopt LOCAL_OPTIONS NO_ERR_EXIT
  local total_bytes=0
  local category_name=""
  local target_path=""
  local size_bytes=0
  local formatted_size=""
  local cache_total=0
  local cache_non_apple=0
  local docker_size=""
  local bundle_name=""
  local bundle_size=0
  local file_basename=""
  local file_size=0
  local user_tmp_size=0
  local user_var_size=0
  local current_user=""
  local owner=""
  local item_size=0
  local item=""

  current_user="${USER}"

  mac_ops_log_info "Starting disk space analysis..."
  echo ""
  echo "$(mac_ops_color_bold '==========================================')"
  echo "$(mac_ops_color_bold '        mac-ops Disk Space Analysis')"
  echo "$(mac_ops_color_bold '==========================================')"
  echo ""

  # 1. ~/Library/Caches
  category_name="System Cache"
  target_path="${HOME}/Library/Caches"
  if [[ -d "${target_path}" ]]; then
    cache_total=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${cache_total}")
    echo "$(mac_ops_color_blue '●') ${category_name} (Total): ${formatted_size}"

    # Calculate size excluding com.apple.*
    cache_non_apple=0
    for bundle_dir in "${target_path}"/*(/N); do
      bundle_name=$(basename "${bundle_dir}")
      if [[ "${bundle_name}" != com.apple.* ]]; then
        bundle_size=$(mac_ops_get_dir_size "${bundle_dir}")
        cache_non_apple=$((cache_non_apple + bundle_size))
      fi
    done

    # Include top-level files (excluding com.apple.*)
    for cache_file in "${target_path}"/*(-.N); do
      file_basename=$(basename "${cache_file}")
      if [[ "${file_basename}" != com.apple.* ]]; then
        file_size=$(mac_ops_get_dir_size "${cache_file}")
        cache_non_apple=$((cache_non_apple + file_size))
      fi
    done

    formatted_size=$(mac_ops_format_bytes "${cache_non_apple}")
    echo "  $(mac_ops_color_green '└─') Excluding Apple: ${formatted_size}"
    total_bytes=$((total_bytes + cache_non_apple))
    mac_ops_log_debug "System cache: ${formatted_size} (Excluding Apple)"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
    mac_ops_log_debug "System cache directory not found"
  fi

  # 2. ~/Library/Logs
  category_name="System Logs"
  target_path="${HOME}/Library/Logs"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "System logs: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 3. ~/Library/Developer/Xcode/DerivedData
  category_name="Xcode DerivedData"
  target_path="${HOME}/Library/Developer/Xcode/DerivedData"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "Xcode DerivedData: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: Not installed"
  fi

  # 4. Homebrew cache
  category_name="Homebrew Cache"
  if command -v brew &>/dev/null; then
    target_path=$(brew --cache 2>/dev/null)
    if [[ -n "${target_path}" && -d "${target_path}" ]]; then
      size_bytes=$(mac_ops_get_dir_size "${target_path}")
      formatted_size=$(mac_ops_format_bytes "${size_bytes}")
      echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
      total_bytes=$((total_bytes + size_bytes))
      mac_ops_log_debug "Homebrew cache: ${formatted_size}"
    else
      echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
    fi
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: Not installed"
  fi

  # 5. npm cache
  category_name="npm Cache"
  target_path="${HOME}/.npm/_cacache"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "npm cache: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 6. yarn cache
  category_name="Yarn Cache"
  target_path="${HOME}/.yarn/cache"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "Yarn cache: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 7. pnpm cache
  category_name="pnpm Store"
  target_path="${HOME}/.pnpm-store"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "pnpm Store: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 8. pip cache
  category_name="pip Cache"
  target_path="${HOME}/.cache/pip"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "pip cache: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 9. Gradle cache
  category_name="Gradle Cache"
  target_path="${HOME}/.gradle/caches"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "Gradle cache: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 10. /tmp (current user files only)
  category_name="Temporary Files (/tmp)"
  target_path="/tmp"
  if [[ -d "${target_path}" ]]; then
    # Calculate only current user's files
    user_tmp_size=0
    while IFS= read -r item; do
      item_size=$(mac_ops_get_dir_size "${item}")
      user_tmp_size=$((user_tmp_size + item_size))
    done < <(find "${target_path}" -maxdepth 1 -user "${current_user}" 2>/dev/null)
    formatted_size=$(mac_ops_format_bytes "${user_tmp_size}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + user_tmp_size))
    mac_ops_log_debug "Temporary files: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 11. /private/var/folders (current user files only)
  category_name="System Temp Folders"
  target_path="/private/var/folders"
  if [[ -d "${target_path}" ]]; then
    user_var_size=0
    while IFS= read -r item; do
      item_size=$(mac_ops_get_dir_size "${item}")
      user_var_size=$((user_var_size + item_size))
    done < <(find "${target_path}" -maxdepth 3 -type d -user "${current_user}" 2>/dev/null)
    formatted_size=$(mac_ops_format_bytes "${user_var_size}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + user_var_size))
    mac_ops_log_debug "System temp folders: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 12. Browser cache
  echo "$(mac_ops_color_blue '●') Browser Cache:"

  # Safari
  category_name="  Safari"
  target_path="${HOME}/Library/Caches/com.apple.Safari"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "  $(mac_ops_color_green '└─') Safari: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "Safari cache: ${formatted_size}"
  else
    echo "  $(mac_ops_color_green '└─') Safari: N/A"
  fi

  # Chrome
  target_path="${HOME}/Library/Caches/Google/Chrome"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "  $(mac_ops_color_green '└─') Chrome: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "Chrome cache: ${formatted_size}"
  else
    echo "  $(mac_ops_color_green '└─') Chrome: Not installed"
  fi

  # Firefox
  target_path="${HOME}/Library/Caches/Firefox"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "  $(mac_ops_color_green '└─') Firefox: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "Firefox cache: ${formatted_size}"
  else
    echo "  $(mac_ops_color_green '└─') Firefox: Not installed"
  fi

  # 13. Docker
  category_name="Docker"
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    docker_size=$(docker system df --format "{{.Size}}" 2>/dev/null | head -1)
    if [[ -n "${docker_size}" ]]; then
      echo "$(mac_ops_color_blue '●') ${category_name}: ${docker_size}"
      mac_ops_log_debug "Docker: ${docker_size}"
      # Docker size is not included in total_bytes (managed separately)
    else
      echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
    fi
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: Not installed or not running"
  fi

  # 14. mac-ops trash
  category_name="mac-ops Trash"
  target_path="${HOME}/.mac-ops/.trash"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "mac-ops trash: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # Total summary
  echo ""
  echo "$(mac_ops_color_bold '==========================================')"
  formatted_size=$(mac_ops_format_bytes "${total_bytes}")
  echo "$(mac_ops_color_bold "Total Reclaimable Space: $(mac_ops_color_green "${formatted_size}")")"
  echo "$(mac_ops_color_bold '==========================================')"
  echo ""

  mac_ops_log_info "Disk space analysis completed: Total ${formatted_size}"

  return 0
}
