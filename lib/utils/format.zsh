# lib/utils/format.zsh
# Formatting and output utilities

# Convert bytes to human-readable format
# Args: bytes
# Returns: Outputs formatted string to stdout
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

# Convert seconds to human-readable format
# Args: seconds
# Returns: Outputs formatted string to stdout
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

# Print header (separator + title)
# Args: title
mac_ops_print_header() {
  local title="$1"

  echo ""
  echo "$(mac_ops_color_bold "==========================================")"
  echo "$(mac_ops_color_bold "$title")"
  echo "$(mac_ops_color_bold "==========================================")"
  echo ""
}

# Print execution summary
# Args: cleaned_count, cleaned_bytes, killed_procs
mac_ops_print_summary() {
  local cleaned_count="$1"
  local cleaned_bytes="$2"
  local killed_procs="$3"

  local formatted_size
  formatted_size=$(mac_ops_format_bytes "$cleaned_bytes")

  echo ""
  echo "$(mac_ops_color_bold "=== Execution Summary ===")"

  if [[ -n "$cleaned_count" && "$cleaned_count" != "0" ]]; then
    echo "$(mac_ops_color_green "✓") Files cleaned: ${cleaned_count} items (${formatted_size})"
  fi

  if [[ -n "$killed_procs" && "$killed_procs" != "0" ]]; then
    echo "$(mac_ops_color_green "✓") Processes terminated: ${killed_procs} items"
  fi

  if [[ "$cleaned_count" == "0" && "$killed_procs" == "0" ]]; then
    echo "$(mac_ops_color_blue "ℹ") No items to clean"
  fi

  echo ""
}

# Print table row (aligned 3 columns)
# Args: col1, col2, col3
mac_ops_print_table_row() {
  local col1="$1"
  local col2="$2"
  local col3="$3"

  # Set width for each column
  local width1=30
  local width2=40
  local width3=20

  printf "%-${width1}s %-${width2}s %-${width3}s\n" "$col1" "$col2" "$col3"
}
