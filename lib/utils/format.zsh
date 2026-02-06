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
    # shellcheck disable=SC2079
    printf "%.1f KB\n" $(( bytes / 1024.0 ))
  elif (( bytes < 1073741824 )); then
    # shellcheck disable=SC2079
    printf "%.1f MB\n" $(( bytes / 1048576.0 ))
  else
    # shellcheck disable=SC2079
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

# Print system report with before/after snapshots and cleanup summary
# Args: before_snapshot, after_snapshot, cleaned_count, cleaned_bytes, killed_procs
# Snapshot format: "disk_usage_pct disk_available_bytes mem_used_bytes mem_total_bytes"
mac_ops_print_report() {
  local before_snapshot="$1"
  local after_snapshot="$2"
  local cleaned_count="$3"
  local cleaned_bytes="$4"
  local killed_procs="$5"

  # Parse before snapshot
  local before_disk_usage before_disk_free before_mem_used before_mem_total
  read -r before_disk_usage before_disk_free before_mem_used before_mem_total <<< "$before_snapshot"

  # Parse after snapshot
  local after_disk_usage after_disk_free after_mem_used after_mem_total
  read -r after_disk_usage after_disk_free after_mem_used after_mem_total <<< "$after_snapshot"

  # Calculate deltas
  local disk_usage_delta=$(( after_disk_usage - before_disk_usage ))
  local disk_free_delta=$(( after_disk_free - before_disk_free ))
  local mem_used_delta=$(( after_mem_used - before_mem_used ))

  # Format bytes for display
  local before_disk_free_fmt after_disk_free_fmt before_mem_used_fmt after_mem_used_fmt
  before_disk_free_fmt=$(mac_ops_format_bytes "$before_disk_free")
  after_disk_free_fmt=$(mac_ops_format_bytes "$after_disk_free")
  before_mem_used_fmt=$(mac_ops_format_bytes "$before_mem_used")
  after_mem_used_fmt=$(mac_ops_format_bytes "$after_mem_used")

  local disk_free_delta_abs mem_used_delta_abs
  if (( disk_free_delta < 0 )); then
    disk_free_delta_abs=$(( -disk_free_delta ))
  else
    disk_free_delta_abs=$disk_free_delta
  fi
  if (( mem_used_delta < 0 )); then
    mem_used_delta_abs=$(( -mem_used_delta ))
  else
    mem_used_delta_abs=$mem_used_delta
  fi

  local disk_free_delta_fmt mem_used_delta_fmt
  disk_free_delta_fmt=$(mac_ops_format_bytes "$disk_free_delta_abs")
  mem_used_delta_fmt=$(mac_ops_format_bytes "$mem_used_delta_abs")

  echo ""
  echo "$(mac_ops_color_bold "=== System Report ===")"

  # Disk usage row with color coding
  local disk_usage_indicator
  if (( disk_usage_delta < 0 )); then
    disk_usage_indicator="$(mac_ops_color_green "↓")"
  elif (( disk_usage_delta == 0 )); then
    disk_usage_indicator="="
  else
    disk_usage_indicator="$(mac_ops_color_yellow "↑")"
  fi

  printf "%-12s : %6s   →  %6s   (%s %s%%)\n" \
    "Disk" \
    "${before_disk_usage}%" \
    "${after_disk_usage}%" \
    "$disk_usage_indicator" \
    "${disk_usage_delta#-}"

  # Disk free row with color coding
  local disk_free_indicator
  if (( disk_free_delta > 0 )); then
    disk_free_indicator="$(mac_ops_color_green "↑")"
  elif (( disk_free_delta == 0 )); then
    disk_free_indicator="="
  else
    disk_free_indicator="$(mac_ops_color_yellow "↓")"
  fi

  printf "%-12s : %9s →  %9s (%s %s)\n" \
    "Disk Free" \
    "$before_disk_free_fmt" \
    "$after_disk_free_fmt" \
    "$disk_free_indicator" \
    "$disk_free_delta_fmt"

  # Memory used row with color coding
  local mem_used_indicator
  if (( mem_used_delta < 0 )); then
    mem_used_indicator="$(mac_ops_color_green "↓")"
  elif (( mem_used_delta == 0 )); then
    mem_used_indicator="="
  else
    mem_used_indicator="$(mac_ops_color_yellow "↑")"
  fi

  printf "%-12s : %9s →  %9s (%s %s)\n" \
    "Memory" \
    "$before_mem_used_fmt" \
    "$after_mem_used_fmt" \
    "$mem_used_indicator" \
    "$mem_used_delta_fmt"

  echo ""
  echo "$(mac_ops_color_bold "=== Cleanup Summary ===")"

  local formatted_size
  formatted_size=$(mac_ops_format_bytes "$cleaned_bytes")

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
