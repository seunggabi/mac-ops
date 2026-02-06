# =============================================================================
# mac-ops: 캐시 정리 모듈
# ~/Library/Caches 하위의 오래된 캐시를 디렉토리 단위로 휴지통 이동
# com.apple.* 번들 ID 캐시는 보호
# =============================================================================

# --- 기본 설정 ---
MAC_OPS_CACHE_MAX_AGE_DAYS=${MAC_OPS_CACHE_MAX_AGE_DAYS:-7}

# -----------------------------------------------------------------------------
# 캐시 정리 메인 함수
# 번들 디렉토리 단위로 처리하여 성능 최적화
# -----------------------------------------------------------------------------
mac_ops_cache_cleanup() {
  local cache_dir="${HOME}/Library/Caches"
  local max_age_days="${MAC_OPS_CACHE_MAX_AGE_DAYS}"
  local now_epoch
  now_epoch=$(date +%s)
  local threshold_seconds=$((max_age_days * 86400))
  local bundle_name="" newest_mtime="" age_seconds=0 dir_size=0 file_count=0
  local old_count=0 file_basename="" mtime="" file_size=0

  mac_ops_log_info "캐시 정리 시작: ${cache_dir} (기준: ${max_age_days}일 이상)"

  # 캐시 디렉토리 존재 확인
  if [[ ! -d "${cache_dir}" ]]; then
    mac_ops_log_warn "캐시 디렉토리가 존재하지 않습니다: ${cache_dir}"
    return 0
  fi

  # 캐시 디렉토리 안전성 체크
  if ! mac_ops_is_path_safe "${cache_dir}"; then
    mac_ops_log_error "캐시 디렉토리가 보호된 경로입니다: ${cache_dir}"
    return 1
  fi

  # 하위 디렉토리 순회 (번들 ID 단위)
  for bundle_dir in "${cache_dir}"/*(/N); do
    bundle_name=$(basename "${bundle_dir}")

    # com.apple.* 번들 ID는 건너뜀
    if [[ "${bundle_name}" == com.apple.* ]]; then
      mac_ops_log_debug "Apple 캐시 건너뜀: ${bundle_name}"
      continue
    fi

    # 번들 디렉토리 전체의 최신 수정 시간 확인 (find로 한 번에)
    newest_mtime=$(find "${bundle_dir}" -type f -exec stat -f%m {} + 2>/dev/null | sort -rn | head -1)

    if [[ -z "${newest_mtime}" ]]; then
      continue
    fi

    age_seconds=$((now_epoch - newest_mtime))

    if [[ ${age_seconds} -ge ${threshold_seconds} ]]; then
      dir_size=$(mac_ops_get_dir_size "${bundle_dir}")
      file_count=$(find "${bundle_dir}" -type f 2>/dev/null | wc -l | tr -d ' ')

      if ! mac_ops_check_size_guard "${bundle_dir}"; then
        mac_ops_log_warn "크기 가드 초과로 건너뜀: ${bundle_name} ($(mac_ops_format_bytes ${dir_size}))"
        continue
      fi

      mac_ops_log_info "캐시 디렉토리 정리: ${bundle_name} (${file_count}개 파일, $(mac_ops_format_bytes ${dir_size}))"

      if mac_ops_trash_move "${bundle_dir}" "cache-expired" "cache-cleanup"; then
        MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + file_count))
        MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + dir_size))
      fi
    else
      old_count=$(find "${bundle_dir}" -type f ! -newermt "${max_age_days} days ago" 2>/dev/null | wc -l | tr -d ' ')

      if [[ ${old_count} -gt 0 ]]; then
        mac_ops_log_debug "캐시 일부 오래됨: ${bundle_name} (${old_count}개 파일이 ${max_age_days}일 초과, 최신 파일 존재하여 보류)"
      fi
    fi
  done

  # 최상위 파일도 처리 (디렉토리가 아닌 파일)
  for cache_file in "${cache_dir}"/*(-.N); do
    file_basename=$(basename "${cache_file}")

    # com.apple.* 파일은 건너뜀
    if [[ "${file_basename}" == com.apple.* ]]; then
      mac_ops_log_debug "Apple 캐시 파일 건너뜀: ${file_basename}"
      continue
    fi

    mtime=$(stat -f%m "${cache_file}" 2>/dev/null) || continue
    age_seconds=$((now_epoch - mtime))

    if [[ ${age_seconds} -ge ${threshold_seconds} ]]; then
      if mac_ops_is_path_safe "${cache_file}" && mac_ops_check_size_guard "${cache_file}"; then
        file_size=$(mac_ops_get_dir_size "${cache_file}")
        if mac_ops_trash_move "${cache_file}" "cache-expired" "cache-cleanup"; then
          MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
          MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + file_size))
        fi
      fi
    fi
  done

  mac_ops_log_info "캐시 정리 완료"
  return 0
}
