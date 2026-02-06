# =============================================================================
# mac-ops: Docker 정리 모듈
# 사용하지 않는 이미지, 컨테이너, 볼륨, 빌드 캐시 정리
# =============================================================================

# -----------------------------------------------------------------------------
# Docker 정리
# dangling images, stopped containers, unused volumes, build cache
# 주의: Docker는 자체 삭제 메커니즘 사용 (trash 이동 불가)
# -----------------------------------------------------------------------------
mac_ops_docker_cleanup() {
  # docker 명령어 존재 확인
  if ! command -v docker &>/dev/null; then
    mac_ops_log_info "Docker가 설치되지 않았습니다. 건너뜁니다."
    return 0
  fi

  # Docker 데몬 실행 여부 확인
  if ! docker info &>/dev/null; then
    mac_ops_log_warn "Docker 데몬이 실행되지 않았습니다. 건너뜁니다."
    return 0
  fi

  mac_ops_log_info "Docker 정리를 시작합니다..."
  mac_ops_log_info "(Docker는 자체 삭제 메커니즘을 사용하며 trash로 이동하지 않습니다)"

  local total_reclaimed=0

  # DRY_RUN 모드
  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Docker 정리 작업 예정:"

    # dangling images 확인
    local dangling_images
    dangling_images=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ ${dangling_images} -gt 0 ]]; then
      mac_ops_log_info "[DRY_RUN] - dangling images: ${dangling_images}개"
    fi

    # stopped containers 확인
    local stopped_containers
    stopped_containers=$(docker ps -a -f "status=exited" -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ ${stopped_containers} -gt 0 ]]; then
      mac_ops_log_info "[DRY_RUN] - stopped containers: ${stopped_containers}개"
    fi

    # unused volumes 확인
    local unused_volumes
    unused_volumes=$(docker volume ls -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ ${unused_volumes} -gt 0 ]]; then
      mac_ops_log_info "[DRY_RUN] - unused volumes: ${unused_volumes}개"
    fi

    mac_ops_log_info "[DRY_RUN] - build cache 정리 예정"

    return 0
  fi

  # 1. dangling images 정리
  mac_ops_log_info "dangling images 정리 중..."
  local image_output
  image_output=$(docker image prune -f 2>&1)
  local image_status=$?

  if [[ ${image_status} -eq 0 ]]; then
    # "Total reclaimed space: 1.2GB" 형태에서 숫자 추출
    local image_reclaimed
    image_reclaimed=$(echo "${image_output}" | grep -i "Total reclaimed space" | sed -E 's/.*: ([0-9.]+)([KMGT]?B).*/\1 \2/')

    if [[ -n "${image_reclaimed}" ]]; then
      mac_ops_log_info "dangling images 정리 완료: ${image_reclaimed}"
      # 바이트 변환하여 카운터 업데이트
      local bytes
      bytes=$(_mac_ops_docker_parse_size "${image_reclaimed}")
      total_reclaimed=$((total_reclaimed + bytes))
    else
      mac_ops_log_debug "dangling images: 정리할 항목 없음"
    fi
  else
    mac_ops_log_warn "dangling images 정리 실패: ${image_output}"
  fi

  # 2. stopped containers 정리
  mac_ops_log_info "stopped containers 정리 중..."
  local container_output
  container_output=$(docker container prune -f 2>&1)
  local container_status=$?

  if [[ ${container_status} -eq 0 ]]; then
    local container_reclaimed
    container_reclaimed=$(echo "${container_output}" | grep -i "Total reclaimed space" | sed -E 's/.*: ([0-9.]+)([KMGT]?B).*/\1 \2/')

    if [[ -n "${container_reclaimed}" ]]; then
      mac_ops_log_info "stopped containers 정리 완료: ${container_reclaimed}"
      local bytes
      bytes=$(_mac_ops_docker_parse_size "${container_reclaimed}")
      total_reclaimed=$((total_reclaimed + bytes))
    else
      mac_ops_log_debug "stopped containers: 정리할 항목 없음"
    fi
  else
    mac_ops_log_warn "stopped containers 정리 실패: ${container_output}"
  fi

  # 3. unused volumes 정리
  mac_ops_log_info "unused volumes 정리 중..."
  local volume_output
  volume_output=$(docker volume prune -f 2>&1)
  local volume_status=$?

  if [[ ${volume_status} -eq 0 ]]; then
    local volume_reclaimed
    volume_reclaimed=$(echo "${volume_output}" | grep -i "Total reclaimed space" | sed -E 's/.*: ([0-9.]+)([KMGT]?B).*/\1 \2/')

    if [[ -n "${volume_reclaimed}" ]]; then
      mac_ops_log_info "unused volumes 정리 완료: ${volume_reclaimed}"
      local bytes
      bytes=$(_mac_ops_docker_parse_size "${volume_reclaimed}")
      total_reclaimed=$((total_reclaimed + bytes))
    else
      mac_ops_log_debug "unused volumes: 정리할 항목 없음"
    fi
  else
    mac_ops_log_warn "unused volumes 정리 실패: ${volume_output}"
  fi

  # 4. build cache 정리
  mac_ops_log_info "build cache 정리 중..."
  local builder_output
  builder_output=$(docker builder prune -f 2>&1)
  local builder_status=$?

  if [[ ${builder_status} -eq 0 ]]; then
    local builder_reclaimed
    builder_reclaimed=$(echo "${builder_output}" | grep -i "Total" | sed -E 's/.*: ([0-9.]+)([KMGT]?B).*/\1 \2/')

    if [[ -n "${builder_reclaimed}" ]]; then
      mac_ops_log_info "build cache 정리 완료: ${builder_reclaimed}"
      local bytes
      bytes=$(_mac_ops_docker_parse_size "${builder_reclaimed}")
      total_reclaimed=$((total_reclaimed + bytes))
    else
      mac_ops_log_debug "build cache: 정리할 항목 없음"
    fi
  else
    mac_ops_log_warn "build cache 정리 실패: ${builder_output}"
  fi

  # 전역 카운터 업데이트
  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + total_reclaimed))
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))

  local total_mb=$((total_reclaimed / 1048576))
  mac_ops_log_info "Docker 정리 완료: 총 $(mac_ops_format_bytes ${total_reclaimed}) 확보"

  return 0
}

# =============================================================================
# 내부 헬퍼 함수
# =============================================================================

# Docker 크기 문자열을 바이트로 변환
# 입력 예: "1.2 GB", "500 MB", "10 KB", "0B"
# 출력: 바이트 숫자
_mac_ops_docker_parse_size() {
  local size_str="${1}"

  # 공백 제거 및 대소문자 정규화
  size_str=$(echo "${size_str}" | tr -d ' ' | tr '[:lower:]' '[:upper:]')

  # 숫자 부분과 단위 분리
  local number
  local unit

  if [[ "${size_str}" =~ ^([0-9.]+)([KMGT]?B)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    # 파싱 실패 시 0 반환
    echo "0"
    return 0
  fi

  # 소수점을 정수로 변환 (1.2 -> 12, 10배)
  local int_number
  if [[ "${number}" == *.* ]]; then
    # 소수점 제거하고 10배
    int_number=$(echo "${number}" | sed 's/\.//' | sed 's/^0*//')
    [[ -z "${int_number}" ]] && int_number=0
  else
    int_number=$((number * 10))
  fi

  # 단위별 변환
  local bytes=0
  case "${unit}" in
    B)
      bytes=$((int_number / 10))
      ;;
    KB)
      bytes=$((int_number * 1024 / 10))
      ;;
    MB)
      bytes=$((int_number * 1048576 / 10))
      ;;
    GB)
      bytes=$((int_number * 1073741824 / 10))
      ;;
    TB)
      bytes=$((int_number * 1099511627776 / 10))
      ;;
    *)
      bytes=0
      ;;
  esac

  echo "${bytes}"
  return 0
}
