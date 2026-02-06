# =============================================================================
# mac-ops: Homebrew 정리 모듈
# brew 캐시 및 오래된 formula 정리
# =============================================================================

# -----------------------------------------------------------------------------
# Homebrew 캐시 및 오래된 패키지 정리
# 사용법: mac_ops_brew_cleanup
# -----------------------------------------------------------------------------
mac_ops_brew_cleanup() {
  # brew 명령어 존재 확인
  if ! command -v brew &>/dev/null; then
    mac_ops_log_info "Homebrew가 설치되지 않았습니다. 건너뜁니다."
    return 0
  fi

  mac_ops_log_info "Homebrew 정리를 시작합니다..."

  local cache_dir
  cache_dir=$(brew --cache 2>/dev/null)

  if [[ -z "${cache_dir}" || ! -d "${cache_dir}" ]]; then
    mac_ops_log_warn "Homebrew 캐시 디렉토리를 찾을 수 없습니다."
    return 1
  fi

  # 캐시 디렉토리 크기 계산
  local cache_size
  cache_size=$(mac_ops_get_dir_size "${cache_dir}")
  local cache_mb=$((cache_size / 1048576))

  # DRY_RUN 모드
  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Homebrew 캐시 정리 예정: ${cache_dir} ($(mac_ops_format_bytes ${cache_size}))"

    # 오래된 formula 목록 확인
    local cleanup_preview
    cleanup_preview=$(brew cleanup --dry-run 2>&1)
    if [[ -n "${cleanup_preview}" ]]; then
      mac_ops_log_info "[DRY_RUN] brew cleanup 실행 예정:"
      echo "${cleanup_preview}" | head -20
    fi

    return 0
  fi

  # 실제 정리 전 크기 기록
  local before_size
  before_size=$(mac_ops_get_dir_size "${cache_dir}")

  # brew cleanup 실행 (7일 이상 된 것 정리)
  mac_ops_log_info "brew cleanup 실행 중 (--prune=7)..."

  local cleanup_output
  cleanup_output=$(brew cleanup --prune=7 2>&1)
  local cleanup_status=$?

  if [[ ${cleanup_status} -ne 0 ]]; then
    mac_ops_log_error "brew cleanup 실패: ${cleanup_output}"
    return 1
  fi

  # 정리 후 크기 계산
  local after_size
  after_size=$(mac_ops_get_dir_size "${cache_dir}")

  local freed_bytes=$((before_size - after_size))

  # 음수 방지 (정리 중 새로운 캐시 생성 가능)
  if [[ ${freed_bytes} -lt 0 ]]; then
    freed_bytes=0
  fi

  # 전역 카운터 업데이트
  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + freed_bytes))

  # 정리된 파일 수 추정 (brew cleanup 출력에서 추출 시도)
  local cleaned_count
  cleaned_count=$(echo "${cleanup_output}" | grep -c "Removing:" || echo 0)
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + cleaned_count))

  local freed_mb=$((freed_bytes / 1048576))
  mac_ops_log_info "Homebrew 정리 완료: ${cleaned_count}개 항목, $(mac_ops_format_bytes ${freed_bytes}) 확보"

  # 정리 결과 요약 출력
  if [[ -n "${cleanup_output}" ]]; then
    mac_ops_log_debug "brew cleanup 출력: ${cleanup_output}"
  fi

  return 0
}
