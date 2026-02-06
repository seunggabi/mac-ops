# lib/utils/notify.zsh
# macOS 시스템 알림 유틸리티

# macOS 시스템 알림 전송
# 인자: title, message
# MAC_OPS_SCHEDULED=true일 때만 알림 전송 (인터랙티브 모드에서는 stdout으로 이미 보임)
mac_ops_notify() {
  local title="$1"
  local message="$2"

  # 스케줄 모드가 아니면 알림하지 않음
  if [[ "$MAC_OPS_SCHEDULED" != "true" ]]; then
    return 0
  fi

  # osascript가 실패해도 (예: headless 환경) 에러를 무시
  osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
  return 0
}

# 정리 완료 알림
# 인자: cleaned_count, cleaned_bytes, killed_procs
# 정리된 항목이 0이면 알림하지 않음
mac_ops_notify_completion() {
  local cleaned_count="$1"
  local cleaned_bytes="$2"
  local killed_procs="$3"
  local formatted_size
  local message_parts=()
  local message

  # 정리된 항목이 없으면 알림하지 않음
  if [[ "$cleaned_count" == "0" && "$killed_procs" == "0" ]]; then
    return 0
  fi

  # 메시지 구성
  if [[ -n "$cleaned_count" && "$cleaned_count" != "0" ]]; then
    formatted_size=$(mac_ops_format_bytes "$cleaned_bytes")
    message_parts+=("파일 ${cleaned_count}개 정리, ${formatted_size} 확보")
  fi

  if [[ -n "$killed_procs" && "$killed_procs" != "0" ]]; then
    message_parts+=("프로세스 ${killed_procs}개 종료")
  fi

  # 메시지 결합
  message="${(j:, :)message_parts}"

  # 알림 전송
  mac_ops_notify "Mac-Ops 정리 완료" "$message"
}
