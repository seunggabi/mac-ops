# lib/utils/format.zsh
# 포맷팅 및 출력 유틸리티

# 바이트를 사람이 읽기 좋은 형식으로 변환
# 인자: bytes
# 반환: stdout에 포맷된 문자열 출력
mac_ops_format_bytes() {
  local bytes="$1"

  if [[ -z "$bytes" || ! "$bytes" =~ ^[0-9]+$ ]]; then
    echo "0 B"
    return 0
  fi

  if (( bytes < 1024 )); then
    echo "${bytes} B"
  elif (( bytes < 1048576 )); then
    printf "%.1f KB\n" $(( bytes / 1024.0 ))
  elif (( bytes < 1073741824 )); then
    printf "%.1f MB\n" $(( bytes / 1048576.0 ))
  else
    printf "%.1f GB\n" $(( bytes / 1073741824.0 ))
  fi
}

# 초를 사람이 읽기 좋은 형식으로 변환
# 인자: seconds
# 반환: stdout에 포맷된 문자열 출력
mac_ops_format_duration() {
  local seconds="$1"

  if [[ -z "$seconds" || ! "$seconds" =~ ^[0-9]+$ ]]; then
    echo "0s"
    return 0
  fi

  if (( seconds < 60 )); then
    echo "${seconds}s"
  elif (( seconds < 3600 )); then
    local mins=$(( seconds / 60 ))
    local secs=$(( seconds % 60 ))
    echo "${mins}m ${secs}s"
  else
    local hours=$(( seconds / 3600 ))
    local mins=$(( (seconds % 3600) / 60 ))
    echo "${hours}h ${mins}m"
  fi
}

# ANSI 색상 코드
mac_ops_color_red() {
  echo "\033[31m${1}\033[0m"
}

mac_ops_color_green() {
  echo "\033[32m${1}\033[0m"
}

mac_ops_color_yellow() {
  echo "\033[33m${1}\033[0m"
}

mac_ops_color_blue() {
  echo "\033[34m${1}\033[0m"
}

mac_ops_color_bold() {
  echo "\033[1m${1}\033[0m"
}

mac_ops_color_reset() {
  echo "\033[0m"
}

# 헤더 출력 (구분선 + 제목)
# 인자: title
mac_ops_print_header() {
  local title="$1"

  echo ""
  echo "$(mac_ops_color_bold "==========================================")"
  echo "$(mac_ops_color_bold "$title")"
  echo "$(mac_ops_color_bold "==========================================")"
  echo ""
}

# 실행 요약 출력
# 인자: cleaned_count, cleaned_bytes, killed_procs
mac_ops_print_summary() {
  local cleaned_count="$1"
  local cleaned_bytes="$2"
  local killed_procs="$3"

  local formatted_size
  formatted_size=$(mac_ops_format_bytes "$cleaned_bytes")

  echo ""
  echo "$(mac_ops_color_bold "=== 실행 요약 ===")"

  if [[ -n "$cleaned_count" && "$cleaned_count" != "0" ]]; then
    echo "$(mac_ops_color_green "✓") 정리된 파일: ${cleaned_count}개 (${formatted_size})"
  fi

  if [[ -n "$killed_procs" && "$killed_procs" != "0" ]]; then
    echo "$(mac_ops_color_green "✓") 종료된 프로세스: ${killed_procs}개"
  fi

  if [[ "$cleaned_count" == "0" && "$killed_procs" == "0" ]]; then
    echo "$(mac_ops_color_blue "ℹ") 정리할 항목이 없습니다"
  fi

  echo ""
}

# 테이블 행 출력 (정렬된 3열)
# 인자: col1, col2, col3
mac_ops_print_table_row() {
  local col1="$1"
  local col2="$2"
  local col3="$3"

  # 각 열의 너비 설정
  local width1=30
  local width2=40
  local width3=20

  printf "%-${width1}s %-${width2}s %-${width3}s\n" "$col1" "$col2" "$col3"
}
