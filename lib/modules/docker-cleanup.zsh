# =============================================================================
# mac-ops: Docker cleanup module
# Clean unused images, containers, volumes, and build cache
# =============================================================================

# -----------------------------------------------------------------------------
# Docker cleanup
# dangling images, stopped containers, unused volumes, build cache
# Note: Docker uses its own deletion mechanism (cannot move to trash)
# -----------------------------------------------------------------------------
mac_ops_docker_cleanup() {
  # Check if docker command exists
  if ! command -v docker &>/dev/null; then
    mac_ops_log_info "Docker is not installed. Skipping."
    return 0
  fi

  # Check if Docker daemon is running
  if ! docker info &>/dev/null; then
    mac_ops_log_warn "Docker daemon is not running. Skipping."
    return 0
  fi

  mac_ops_log_info "Starting Docker cleanup..."
  mac_ops_log_info "(Docker uses its own deletion mechanism and does not move to trash)"

  local total_reclaimed=0

  # DRY_RUN mode
  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Will perform Docker cleanup:"

    # Check dangling images
    local dangling_images
    dangling_images=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ ${dangling_images} -gt 0 ]]; then
      mac_ops_log_info "[DRY_RUN] - dangling images: ${dangling_images} items"
    fi

    # Check stopped containers
    local stopped_containers
    stopped_containers=$(docker ps -a -f "status=exited" -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ ${stopped_containers} -gt 0 ]]; then
      mac_ops_log_info "[DRY_RUN] - stopped containers: ${stopped_containers} items"
    fi

    # Check unused volumes
    local unused_volumes
    unused_volumes=$(docker volume ls -f "dangling=true" -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ ${unused_volumes} -gt 0 ]]; then
      mac_ops_log_info "[DRY_RUN] - unused volumes: ${unused_volumes} items"
    fi

    mac_ops_log_info "[DRY_RUN] - Will clean build cache"

    return 0
  fi

  # 1. Clean dangling images
  mac_ops_log_info "Cleaning dangling images..."
  local image_output
  image_output=$(docker image prune -f 2>&1)
  local image_status=$?

  if [[ ${image_status} -eq 0 ]]; then
    # Extract numbers from "Total reclaimed space: 1.2GB" format
    local image_reclaimed
    image_reclaimed=$(echo "${image_output}" | grep -i "Total reclaimed space" | sed -E 's/.*: ([0-9.]+)([KMGT]?B).*/\1 \2/')

    if [[ -n "${image_reclaimed}" ]]; then
      mac_ops_log_info "Dangling images cleanup completed: ${image_reclaimed}"
      # Convert to bytes and update counter
      local bytes
      bytes=$(_mac_ops_docker_parse_size "${image_reclaimed}")
      total_reclaimed=$((total_reclaimed + bytes))
    else
      mac_ops_log_debug "dangling images: No items to clean"
    fi
  else
    mac_ops_log_warn "Dangling images cleanup failed: ${image_output}"
  fi

  # 2. Clean stopped containers
  mac_ops_log_info "Cleaning stopped containers..."
  local container_output
  container_output=$(docker container prune -f 2>&1)
  local container_status=$?

  if [[ ${container_status} -eq 0 ]]; then
    local container_reclaimed
    container_reclaimed=$(echo "${container_output}" | grep -i "Total reclaimed space" | sed -E 's/.*: ([0-9.]+)([KMGT]?B).*/\1 \2/')

    if [[ -n "${container_reclaimed}" ]]; then
      mac_ops_log_info "Stopped containers cleanup completed: ${container_reclaimed}"
      local bytes
      bytes=$(_mac_ops_docker_parse_size "${container_reclaimed}")
      total_reclaimed=$((total_reclaimed + bytes))
    else
      mac_ops_log_debug "stopped containers: No items to clean"
    fi
  else
    mac_ops_log_warn "Stopped containers cleanup failed: ${container_output}"
  fi

  # 3. Clean unused volumes
  mac_ops_log_info "Cleaning unused volumes..."
  local volume_output
  volume_output=$(docker volume prune -f 2>&1)
  local volume_status=$?

  if [[ ${volume_status} -eq 0 ]]; then
    local volume_reclaimed
    volume_reclaimed=$(echo "${volume_output}" | grep -i "Total reclaimed space" | sed -E 's/.*: ([0-9.]+)([KMGT]?B).*/\1 \2/')

    if [[ -n "${volume_reclaimed}" ]]; then
      mac_ops_log_info "Unused volumes cleanup completed: ${volume_reclaimed}"
      local bytes
      bytes=$(_mac_ops_docker_parse_size "${volume_reclaimed}")
      total_reclaimed=$((total_reclaimed + bytes))
    else
      mac_ops_log_debug "unused volumes: No items to clean"
    fi
  else
    mac_ops_log_warn "Unused volumes cleanup failed: ${volume_output}"
  fi

  # 4. Clean build cache
  mac_ops_log_info "Cleaning build cache..."
  local builder_output
  builder_output=$(docker builder prune -f 2>&1)
  local builder_status=$?

  if [[ ${builder_status} -eq 0 ]]; then
    local builder_reclaimed
    builder_reclaimed=$(echo "${builder_output}" | grep -i "Total" | sed -E 's/.*: ([0-9.]+)([KMGT]?B).*/\1 \2/')

    if [[ -n "${builder_reclaimed}" ]]; then
      mac_ops_log_info "Build cache cleanup completed: ${builder_reclaimed}"
      local bytes
      bytes=$(_mac_ops_docker_parse_size "${builder_reclaimed}")
      total_reclaimed=$((total_reclaimed + bytes))
    else
      mac_ops_log_debug "build cache: No items to clean"
    fi
  else
    mac_ops_log_warn "Build cache cleanup failed: ${builder_output}"
  fi

  # Update global counter
  MAC_OPS_CLEANED_BYTES=$((MAC_OPS_CLEANED_BYTES + total_reclaimed))
  MAC_OPS_CLEANED_COUNT=$((MAC_OPS_CLEANED_COUNT + 1))

  local total_mb=$((total_reclaimed / 1048576))
  mac_ops_log_info "Docker cleanup completed: Total $(mac_ops_format_bytes ${total_reclaimed}) freed"

  return 0
}

# =============================================================================
# Internal helper functions
# =============================================================================

# Convert Docker size string to bytes
# Input example: "1.2 GB", "500 MB", "10 KB", "0B"
# Output: bytes number
_mac_ops_docker_parse_size() {
  local size_str="${1}"

  # Remove whitespace and normalize case
  size_str=$(echo "${size_str}" | tr -d ' ' | tr '[:lower:]' '[:upper:]')

  # Separate number and unit
  local number
  local unit

  if [[ "${size_str}" =~ ^([0-9.]+)([KMGT]?B)$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    # Return 0 on parsing failure
    echo "0"
    return 0
  fi

  # Convert decimal to integer (1.2 -> 12, multiply by 10)
  local int_number
  if [[ "${number}" == *.* ]]; then
    # Remove decimal point and multiply by 10
    int_number=$(echo "${number}" | sed 's/\.//' | sed 's/^0*//')
    [[ -z "${int_number}" ]] && int_number=0
  else
    int_number=$((number * 10))
  fi

  # Convert by unit
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
