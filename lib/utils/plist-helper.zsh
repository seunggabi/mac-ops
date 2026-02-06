# lib/utils/plist-helper.zsh
# plist 파일 조작 유틸리티

# plist 파일에서 특정 키의 값 읽기
# 인자: file, key
# 반환: stdout에 값 출력
mac_ops_plist_read() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    echo "plist 파일이 존재하지 않습니다: $file" >&2
    return 1
  fi

  if [[ -z "$key" ]]; then
    echo "키가 지정되지 않았습니다" >&2
    return 1
  fi

  /usr/libexec/PlistBuddy -c "Print :${key}" "${file}" 2>/dev/null
  return $?
}

# plist 파일에 키-값 쓰기
# 인자: file, key, type, value
# type: string, integer, bool, date
mac_ops_plist_write() {
  local file="$1"
  local key="$2"
  local type="$3"
  local value="$4"

  if [[ ! -f "$file" ]]; then
    echo "plist 파일이 존재하지 않습니다: $file" >&2
    return 1
  fi

  if [[ -z "$key" || -z "$type" || -z "$value" ]]; then
    echo "키, 타입, 값이 모두 필요합니다" >&2
    return 1
  fi

  # 지원하는 타입 검증
  case "$type" in
    string|integer|bool|date)
      ;;
    *)
      echo "지원하지 않는 타입: $type (string, integer, bool, date만 지원)" >&2
      return 1
      ;;
  esac

  # 키가 이미 존재하는지 확인
  if mac_ops_plist_exists "$file" "$key"; then
    # 기존 키 업데이트
    /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${file}" 2>/dev/null
  else
    # 새 키 추가
    /usr/libexec/PlistBuddy -c "Add :${key} ${type} ${value}" "${file}" 2>/dev/null
  fi

  return $?
}

# 메타데이터 plist 파일 생성
# 인자: file, original_path, trash_path, size_bytes, reason, module, status
mac_ops_plist_create_metadata() {
  local file="$1"
  local original_path="$2"
  local trash_path="$3"
  local size_bytes="$4"
  local reason="$5"
  local module="$6"
  local status="$7"

  if [[ -z "$file" || -z "$original_path" || -z "$trash_path" ]]; then
    echo "필수 인자가 누락되었습니다" >&2
    return 1
  fi

  # 디렉토리 생성
  local dir
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || return 1

  # 빈 plist 생성
  /usr/libexec/PlistBuddy -c "Save" "${file}" 2>/dev/null || return 1

  # 현재 시간 (ISO8601 형식)
  local moved_at
  moved_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # 만료 시간 계산 (MAC_OPS_TRASH_RETENTION_HOURS 기본값 720시간 = 30일)
  local retention_hours=${MAC_OPS_TRASH_RETENTION_HOURS:-720}
  local expires_at
  expires_at=$(date -u -v+${retention_hours}H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    # macOS 구버전 호환성
    expires_at=$(date -u -d "+${retention_hours} hours" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  fi

  # 모든 필드 추가
  /usr/libexec/PlistBuddy -c "Add :OriginalPath string ${original_path}" "${file}" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add :TrashPath string ${trash_path}" "${file}" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add :SizeBytes integer ${size_bytes:-0}" "${file}" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add :Reason string ${reason:-Unknown}" "${file}" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add :Module string ${module:-Unknown}" "${file}" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add :Status string ${status:-moved}" "${file}" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add :MovedAt date ${moved_at}" "${file}" 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add :ExpiresAt date ${expires_at}" "${file}" 2>/dev/null

  return $?
}

# plist에서 키 삭제
# 인자: file, key
mac_ops_plist_delete() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    echo "plist 파일이 존재하지 않습니다: $file" >&2
    return 1
  fi

  if [[ -z "$key" ]]; then
    echo "키가 지정되지 않았습니다" >&2
    return 1
  fi

  /usr/libexec/PlistBuddy -c "Delete :${key}" "${file}" 2>/dev/null
  return $?
}

# 키 존재 여부 확인
# 인자: file, key
# 반환: 존재하면 0, 없으면 1
mac_ops_plist_exists() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  if [[ -z "$key" ]]; then
    return 1
  fi

  /usr/libexec/PlistBuddy -c "Print :${key}" "${file}" &>/dev/null
  return $?
}
