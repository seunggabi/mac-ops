# =============================================================================
# mac-ops: 공간 분석 모듈
# 각 정리 대상 경로의 현재 크기를 분석하여 리포트 출력
# =============================================================================

# -----------------------------------------------------------------------------
# 공간 분석 리포트
# 각 정리 대상 경로의 현재 크기를 확인하여 절약 가능한 공간 표시
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

  mac_ops_log_info "디스크 공간 분석을 시작합니다..."
  echo ""
  echo "$(mac_ops_color_bold '==========================================')"
  echo "$(mac_ops_color_bold '        mac-ops 디스크 공간 분석')"
  echo "$(mac_ops_color_bold '==========================================')"
  echo ""

  # 1. ~/Library/Caches
  category_name="시스템 캐시"
  target_path="${HOME}/Library/Caches"
  if [[ -d "${target_path}" ]]; then
    cache_total=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${cache_total}")
    echo "$(mac_ops_color_blue '●') ${category_name} (전체): ${formatted_size}"

    # com.apple.* 제외한 크기 계산
    cache_non_apple=0
    for bundle_dir in "${target_path}"/*(/N); do
      bundle_name=$(basename "${bundle_dir}")
      if [[ "${bundle_name}" != com.apple.* ]]; then
        bundle_size=$(mac_ops_get_dir_size "${bundle_dir}")
        cache_non_apple=$((cache_non_apple + bundle_size))
      fi
    done

    # 최상위 파일도 포함 (com.apple.* 제외)
    for cache_file in "${target_path}"/*(-.N); do
      file_basename=$(basename "${cache_file}")
      if [[ "${file_basename}" != com.apple.* ]]; then
        file_size=$(mac_ops_get_dir_size "${cache_file}")
        cache_non_apple=$((cache_non_apple + file_size))
      fi
    done

    formatted_size=$(mac_ops_format_bytes "${cache_non_apple}")
    echo "  $(mac_ops_color_green '└─') Apple 제외: ${formatted_size}"
    total_bytes=$((total_bytes + cache_non_apple))
    mac_ops_log_debug "시스템 캐시: ${formatted_size} (Apple 제외)"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
    mac_ops_log_debug "시스템 캐시 디렉토리 없음"
  fi

  # 2. ~/Library/Logs
  category_name="시스템 로그"
  target_path="${HOME}/Library/Logs"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "시스템 로그: ${formatted_size}"
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
    echo "$(mac_ops_color_blue '●') ${category_name}: 미설치"
  fi

  # 4. Homebrew 캐시
  category_name="Homebrew 캐시"
  if command -v brew &>/dev/null; then
    target_path=$(brew --cache 2>/dev/null)
    if [[ -n "${target_path}" && -d "${target_path}" ]]; then
      size_bytes=$(mac_ops_get_dir_size "${target_path}")
      formatted_size=$(mac_ops_format_bytes "${size_bytes}")
      echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
      total_bytes=$((total_bytes + size_bytes))
      mac_ops_log_debug "Homebrew 캐시: ${formatted_size}"
    else
      echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
    fi
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: 미설치"
  fi

  # 5. npm 캐시
  category_name="npm 캐시"
  target_path="${HOME}/.npm/_cacache"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "npm 캐시: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 6. yarn 캐시
  category_name="Yarn 캐시"
  target_path="${HOME}/.yarn/cache"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "Yarn 캐시: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 7. pnpm 캐시
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

  # 8. pip 캐시
  category_name="pip 캐시"
  target_path="${HOME}/.cache/pip"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "pip 캐시: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 9. Gradle 캐시
  category_name="Gradle 캐시"
  target_path="${HOME}/.gradle/caches"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "Gradle 캐시: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 10. /tmp (현재 사용자 파일만)
  category_name="임시 파일 (/tmp)"
  target_path="/tmp"
  if [[ -d "${target_path}" ]]; then
    # 현재 사용자 소유 파일만 계산
    user_tmp_size=0
    for item in "${target_path}"/*(/N) "${target_path}"/*(-.N); do
      if [[ -e "${item}" ]]; then
        owner=$(stat -f%Su "${item}" 2>/dev/null)
        if [[ "${owner}" == "${current_user}" ]]; then
          item_size=$(mac_ops_get_dir_size "${item}")
          user_tmp_size=$((user_tmp_size + item_size))
        fi
      fi
    done
    formatted_size=$(mac_ops_format_bytes "${user_tmp_size}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + user_tmp_size))
    mac_ops_log_debug "임시 파일: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 11. /private/var/folders (현재 사용자 파일만)
  category_name="시스템 임시 폴더"
  target_path="/private/var/folders"
  if [[ -d "${target_path}" ]]; then
    user_var_size=0
    # var/folders는 깊은 구조이므로 find 사용
    while IFS= read -r item; do
      owner=$(stat -f%Su "${item}" 2>/dev/null)
      if [[ "${owner}" == "${current_user}" ]]; then
        item_size=$(mac_ops_get_dir_size "${item}")
        user_var_size=$((user_var_size + item_size))
      fi
    done < <(find "${target_path}" -maxdepth 3 -type d 2>/dev/null)
    formatted_size=$(mac_ops_format_bytes "${user_var_size}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + user_var_size))
    mac_ops_log_debug "시스템 임시 폴더: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 12. 브라우저 캐시
  echo "$(mac_ops_color_blue '●') 브라우저 캐시:"

  # Safari
  category_name="  Safari"
  target_path="${HOME}/Library/Caches/com.apple.Safari"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "  $(mac_ops_color_green '└─') Safari: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "Safari 캐시: ${formatted_size}"
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
    mac_ops_log_debug "Chrome 캐시: ${formatted_size}"
  else
    echo "  $(mac_ops_color_green '└─') Chrome: 미설치"
  fi

  # Firefox
  target_path="${HOME}/Library/Caches/Firefox"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "  $(mac_ops_color_green '└─') Firefox: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "Firefox 캐시: ${formatted_size}"
  else
    echo "  $(mac_ops_color_green '└─') Firefox: 미설치"
  fi

  # 13. Docker
  category_name="Docker"
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    docker_size=$(docker system df --format "{{.Size}}" 2>/dev/null | head -1)
    if [[ -n "${docker_size}" ]]; then
      echo "$(mac_ops_color_blue '●') ${category_name}: ${docker_size}"
      mac_ops_log_debug "Docker: ${docker_size}"
      # Docker 크기는 total_bytes에 포함하지 않음 (별도 관리)
    else
      echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
    fi
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: 미설치 또는 미실행"
  fi

  # 14. mac-ops 휴지통
  category_name="mac-ops 휴지통"
  target_path="${HOME}/.mac-ops/.trash"
  if [[ -d "${target_path}" ]]; then
    size_bytes=$(mac_ops_get_dir_size "${target_path}")
    formatted_size=$(mac_ops_format_bytes "${size_bytes}")
    echo "$(mac_ops_color_blue '●') ${category_name}: ${formatted_size}"
    total_bytes=$((total_bytes + size_bytes))
    mac_ops_log_debug "mac-ops 휴지통: ${formatted_size}"
  else
    echo "$(mac_ops_color_blue '●') ${category_name}: N/A"
  fi

  # 총 합계
  echo ""
  echo "$(mac_ops_color_bold '==========================================')"
  formatted_size=$(mac_ops_format_bytes "${total_bytes}")
  echo "$(mac_ops_color_bold "총 절약 가능 공간: $(mac_ops_color_green "${formatted_size}")")"
  echo "$(mac_ops_color_bold '==========================================')"
  echo ""

  mac_ops_log_info "디스크 공간 분석 완료: 총 ${formatted_size}"

  return 0
}
