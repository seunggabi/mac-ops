# =============================================================================
# mac-ops: Docker cleanup module
# Report Docker disk usage; optionally prune old unused images and build cache
# =============================================================================
#
# Docker deletes permanently: nothing it prunes goes to the mac-ops trash.
# Stopped containers (with their writable layers) and volumes (which can hold
# databases) are data, so this module never prunes them, under any setting,
# and never passes --volumes.
#
# What the module does:
#   report (default) - log `docker system df`, the number of stopped
#                      containers, unused images older than the age limit and
#                      the reclaimable build cache; change nothing
#   prune            - additionally run exactly these two commands:
#                        docker image prune -a --filter "until=<N>h" -f
#                        docker builder prune --filter "until=<N>h" -f
# Only the exact value "prune" acts. Every other value, including an empty
# one, "Prune" or "prune " with a trailing space, behaves like "report".

# zsh-only parameter flags; false positives in bash mode
# shellcheck disable=SC2296,SC2299

MAC_OPS_DOCKER_ACTION=${MAC_OPS_DOCKER_ACTION:-report}

# Age limit for pruned images and build cache, in hours (720 = 30 days)
MAC_OPS_DOCKER_PRUNE_UNTIL_HOURS=${MAC_OPS_DOCKER_PRUNE_UNTIL_HOURS:-720}

# Seconds to wait for `docker info`; a hung daemon must not block the run
MAC_OPS_DOCKER_PROBE_TIMEOUT=${MAC_OPS_DOCKER_PROBE_TIMEOUT:-10}

# -----------------------------------------------------------------------------
# Docker module main function
# Never starts or quits Docker Desktop: an unreachable daemon means "skip".
# -----------------------------------------------------------------------------
mac_ops_docker_cleanup() {
  local hours="${MAC_OPS_DOCKER_PRUNE_UNTIL_HOURS}"

  if ! command -v docker &>/dev/null; then
    mac_ops_log_info "Docker is not installed. Skipping."
    return 0
  fi

  if ! _mac_ops_docker_daemon_reachable; then
    mac_ops_log_warn "Docker daemon is not reachable (not running, or no answer within ${MAC_OPS_DOCKER_PROBE_TIMEOUT}s). Skipping."
    return 0
  fi

  if [[ ! "${hours}" =~ ^[0-9]+$ ]] || (( hours < 24 )); then
    mac_ops_log_warn "MAC_OPS_DOCKER_PRUNE_UNTIL_HOURS='${hours}' is not a whole number of at least 24, using 720"
    hours=720
  fi

  _mac_ops_docker_report "${hours}"

  if [[ "${MAC_OPS_DOCKER_ACTION}" != "prune" ]]; then
    mac_ops_log_info "Docker: report only, nothing removed (set MAC_OPS_DOCKER_ACTION=prune to remove unused images and build cache older than ${hours}h)"
    return 0
  fi

  _mac_ops_docker_prune "${hours}"
  return 0
}

# =============================================================================
# Internal helper functions
# =============================================================================

# -----------------------------------------------------------------------------
# Return 0 if `docker info` succeeds within MAC_OPS_DOCKER_PROBE_TIMEOUT seconds.
# The probe runs as a background job of this shell; on timeout only that job
# (our own child) is terminated.
# -----------------------------------------------------------------------------
_mac_ops_docker_daemon_reachable() {
  local limit="${MAC_OPS_DOCKER_PROBE_TIMEOUT}"
  local pid=0 ticks=0 rc=0

  if [[ ! "${limit}" =~ ^[0-9]+$ ]] || (( limit < 1 )); then
    limit=10
  fi

  docker info >/dev/null 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    if (( ticks >= limit * 10 )); then
      kill -TERM "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      return 1
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "${pid}"
  rc=$?
  return ${rc}
}

# -----------------------------------------------------------------------------
# Log disk usage, stopped containers, old unused images and build cache.
# Read-only: only `system df`, `ps`, `inspect` and `image ls` are called.
# Usage: _mac_ops_docker_report <hours>
# -----------------------------------------------------------------------------
_mac_ops_docker_report() {
  local hours="${1}"
  local df_out="" line="" stopped="" build_cache=""
  local now_epoch=0 cutoff_epoch=0 created_epoch=0 old_images=0
  local image_id="" created="" container_ids=""
  local -A used_images=()

  df_out=$(docker system df 2>/dev/null)
  if [[ -n "${df_out}" ]]; then
    mac_ops_log_info "Docker disk usage (docker system df):"
    while IFS= read -r line; do
      [[ -n "${line}" ]] && mac_ops_log_info "  ${line}"
    done <<< "${df_out}"
  fi

  stopped=$(docker ps -a --filter "status=exited" --filter "status=created" -q 2>/dev/null | grep -c .)
  mac_ops_log_info "Docker: ${stopped:-0} stopped containers (never removed by mac-ops; remove them yourself with docker rm if they hold nothing you need)"

  # Images used by any container, running or stopped, are never "unused"
  container_ids=$(docker ps -a -q 2>/dev/null)
  if [[ -n "${container_ids}" ]]; then
    while IFS= read -r image_id; do
      [[ -n "${image_id}" ]] && used_images[${image_id}]=1
    done < <(docker inspect --format '{{.Image}}' ${(f)container_ids} 2>/dev/null)
  fi

  now_epoch=$(date +%s)
  cutoff_epoch=$((now_epoch - hours * 3600))
  while IFS=$'\t' read -r image_id created; do
    [[ -z "${image_id}" || -n "${used_images[${image_id}]+_}" ]] && continue
    # CreatedAt looks like "2024-05-01 10:00:00 +0900 KST"
    created_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S %z' "${created% *}" +%s 2>/dev/null)
    [[ "${created_epoch}" =~ ^[0-9]+$ ]] || continue
    (( created_epoch < cutoff_epoch )) && old_images=$((old_images + 1))
  done < <(docker image ls --no-trunc --format '{{.ID}}{{"\t"}}{{.CreatedAt}}' 2>/dev/null)
  mac_ops_log_info "Docker: ${old_images} unused images older than ${hours}h"

  build_cache=$(docker system df --format '{{.Type}}{{"\t"}}{{.Reclaimable}}' 2>/dev/null | awk -F'\t' '$1 == "Build Cache" {print $2}')
  mac_ops_log_info "Docker: build cache reclaimable: ${build_cache:-unknown}"
  return 0
}

# -----------------------------------------------------------------------------
# Remove unused images and build cache older than <hours>. Nothing else.
# Usage: _mac_ops_docker_prune <hours>
# -----------------------------------------------------------------------------
_mac_ops_docker_prune() {
  local hours="${1}"
  local filter="until=${hours}h"
  local output="" rc=0 reclaimed="" bytes=0 total=0

  if [[ "${MAC_OPS_DRY_RUN}" == "true" ]]; then
    mac_ops_log_info "[DRY_RUN] Would run: docker image prune -a --filter \"${filter}\" -f"
    mac_ops_log_info "[DRY_RUN] Would run: docker builder prune --filter \"${filter}\" -f"
    return 0
  fi

  mac_ops_log_info "Removing unused images older than ${hours}h (permanent, not moved to the trash)..."
  output=$(docker image prune -a --filter "${filter}" -f 2>&1)
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    reclaimed=$(print -r -- "${output}" | grep -i "Total reclaimed space" | sed -E 's/.*: ([0-9.]+)([KMGT]?B).*/\1 \2/')
    if [[ -n "${reclaimed}" ]]; then
      bytes=$(_mac_ops_docker_parse_size "${reclaimed}")
      total=$((total + bytes))
      mac_ops_log_info "Unused images removed: ${reclaimed}"
    fi
  else
    mac_ops_log_warn "docker image prune failed: ${output}"
  fi

  mac_ops_log_info "Removing build cache older than ${hours}h (permanent, not moved to the trash)..."
  output=$(docker builder prune --filter "${filter}" -f 2>&1)
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    reclaimed=$(print -r -- "${output}" | grep -i "Total" | sed -E 's/.*: ([0-9.]+)([KMGT]?B).*/\1 \2/')
    if [[ -n "${reclaimed}" ]]; then
      bytes=$(_mac_ops_docker_parse_size "${reclaimed}")
      total=$((total + bytes))
      mac_ops_log_info "Build cache removed: ${reclaimed}"
    fi
  else
    mac_ops_log_warn "docker builder prune failed: ${output}"
  fi

  MAC_OPS_CLEANED_BYTES=$((${MAC_OPS_CLEANED_BYTES:-0} + total))
  MAC_OPS_CLEANED_COUNT=$((${MAC_OPS_CLEANED_COUNT:-0} + 1))
  mac_ops_log_info "Docker prune completed: Total $(mac_ops_format_bytes ${total}) freed"
  return 0
}

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

  # shellcheck disable=SC2076
  if [[ "${size_str}" =~ '^([0-9.]+)([KMGT]?B)$' ]]; then
    number="${match[1]}"
    unit="${match[2]}"
  else
    # Return 0 on parsing failure
    echo "0"
    return 0
  fi

  # Convert to integer bytes using awk for correct decimal handling (1.23GB, 0.5MB, etc.)
  local int_number
  int_number=$(awk "BEGIN{printf \"%d\", ${number} * 10}" 2>/dev/null)
  [[ -z "${int_number}" ]] && int_number=0

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
