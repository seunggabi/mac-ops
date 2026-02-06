# lib/utils/plist-helper.zsh
# plist file manipulation utilities

# Read value of specific key from plist file
# Args: file, key
# Returns: Outputs value to stdout
mac_ops_plist_read() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    echo "plist file does not exist: $file" >&2
    return 1
  fi

  if [[ -z "$key" ]]; then
    echo "Key not specified" >&2
    return 1
  fi

  /usr/libexec/PlistBuddy -c "Print :${key}" "${file}" 2>/dev/null
  return $?
}

# Write key-value to plist file
# Args: file, key, type, value
# type: string, integer, bool, date
mac_ops_plist_write() {
  local file="$1"
  local key="$2"
  local type="$3"
  local value="$4"

  if [[ ! -f "$file" ]]; then
    echo "plist file does not exist: $file" >&2
    return 1
  fi

  if [[ -z "$key" || -z "$type" || -z "$value" ]]; then
    echo "Key, type, and value are all required" >&2
    return 1
  fi

  # Validate supported types
  case "$type" in
    string|integer|bool|date)
      ;;
    *)
      echo "Unsupported type: $type (only string, integer, bool, date are supported)" >&2
      return 1
      ;;
  esac

  # Check if key already exists
  if mac_ops_plist_exists "$file" "$key"; then
    # Update existing key
    /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${file}" 2>/dev/null
  else
    # Add new key
    /usr/libexec/PlistBuddy -c "Add :${key} ${type} ${value}" "${file}" 2>/dev/null
  fi

  return $?
}

# Create metadata plist file
# Args: file, original_path, trash_path, size_bytes, reason, module, status
mac_ops_plist_create_metadata() {
  local file="$1"
  local original_path="$2"
  local trash_path="$3"
  local size_bytes="$4"
  local reason="$5"
  local module="$6"
  local status="$7"

  if [[ -z "$file" || -z "$original_path" || -z "$trash_path" ]]; then
    echo "Required arguments missing" >&2
    return 1
  fi

  # Create directory
  local dir
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || return 1

  # Create empty plist
  /usr/libexec/PlistBuddy -c "Save" "${file}" 2>/dev/null || return 1

  # Current time (ISO8601 format)
  local moved_at
  moved_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Calculate expiration time (MAC_OPS_TRASH_RETENTION_HOURS default 720 hours = 30 days)
  local retention_hours=${MAC_OPS_TRASH_RETENTION_HOURS:-720}
  local expires_at
  expires_at=$(date -u -v+${retention_hours}H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    # macOS older version compatibility
    expires_at=$(date -u -d "+${retention_hours} hours" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  fi

  # Add all fields
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

# Delete key from plist
# Args: file, key
mac_ops_plist_delete() {
  local file="$1"
  local key="$2"

  if [[ ! -f "$file" ]]; then
    echo "plist file does not exist: $file" >&2
    return 1
  fi

  if [[ -z "$key" ]]; then
    echo "Key not specified" >&2
    return 1
  fi

  /usr/libexec/PlistBuddy -c "Delete :${key}" "${file}" 2>/dev/null
  return $?
}

# Check if key exists
# Args: file, key
# Returns: 0 if exists, 1 if not
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
