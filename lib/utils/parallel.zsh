# lib/utils/parallel.zsh
# Parallel execution utilities

# Default timeout for parallel module execution (in seconds)
: ${MAC_OPS_PARALLEL_TIMEOUT_SECONDS:=300}

# Wait for PIDs with timeout monitoring
# Args: timeout_seconds pid1 pid2 ...
# Returns: 0 if all processes completed, 1 if any timed out or failed
mac_ops_parallel_wait_with_timeout() {
  local timeout="$1"
  shift
  local -a pids=("$@")

  if [[ ${#pids[@]} -eq 0 ]]; then
    echo "No PIDs specified to wait for" >&2
    return 1
  fi

  # Record start time for each PID
  typeset -A start_times
  typeset -A completed
  local current_time
  current_time=$(date +%s)
  for pid in "${pids[@]}"; do
    start_times[$pid]=$current_time
    completed[$pid]=0
  done

  local -a remaining_pids=("${pids[@]}")
  local check_interval=1
  local has_timeout=0
  local has_failure=0

  # Monitor all PIDs until completion or timeout
  while [[ ${#remaining_pids[@]} -gt 0 ]]; do
    local -a still_running=()
    current_time=$(date +%s)

    for pid in "${remaining_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        # Process still running, check timeout
        local elapsed=$((current_time - start_times[$pid]))
        if [[ $elapsed -ge $timeout ]]; then
          echo "Process $pid exceeded timeout (${timeout}s), terminating..." >&2
          # Try graceful termination first
          kill -TERM "$pid" 2>/dev/null
          sleep 1
          # Force kill if still alive
          if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null
            sleep 0.5
          fi
          # Reap the killed process
          wait "$pid" 2>/dev/null || true
          has_timeout=1
          # Don't add to still_running - it's done
        else
          # Still running and within timeout
          still_running+=("$pid")
        fi
      else
        # Process completed, reap it
        wait "$pid" 2>/dev/null
        local exit_code=$?
        if [[ $exit_code -ne 0 ]]; then
          has_failure=1
        fi
        # Don't add to still_running - it's done
      fi
    done

    remaining_pids=("${still_running[@]}")

    if [[ ${#remaining_pids[@]} -gt 0 ]]; then
      sleep $check_interval
    fi
  done

  [[ $has_timeout -eq 1 || $has_failure -eq 1 ]] && return 1
  return 0
}
