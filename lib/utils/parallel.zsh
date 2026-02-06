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

# Execute multiple functions in parallel
# Args: function name array (space-separated)
# Returns: Outputs failed function list to stdout, returns 0 on success
mac_ops_parallel_run() {
  local -a functions=("$@")
  local -a pids=()
  local -a results=()
  local -a failed=()

  if [[ ${#functions[@]} -eq 0 ]]; then
    echo "No functions specified to execute" >&2
    return 1
  fi

  # Execute each function in background
  for func in "${functions[@]}"; do
    # Check if function exists
    if ! typeset -f "$func" &>/dev/null; then
      echo "Function does not exist: $func" >&2
      failed+=("$func")
      continue
    fi

    # Execute in background
    (
      $func
      exit $?
    ) &

    pids+=($!)
  done

  # Wait for all processes to complete and collect results
  local idx=0
  for pid in "${pids[@]}"; do
    wait $pid
    local exit_code=$?
    results+=($exit_code)

    # Record failed functions
    if [[ $exit_code -ne 0 ]]; then
      failed+=("${functions[$idx]}")
    fi

    ((idx++))
  done

  # Output failed functions if any
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "${failed[@]}"
    return 1
  fi

  return 0
}

# Wait for completion of PID array and collect results
# Args: pid array
# Returns: Outputs exit code array to stdout (space-separated), returns 1 if any failed
mac_ops_parallel_wait() {
  local -a pids=("$@")
  local -a results=()
  local has_failure=0

  if [[ ${#pids[@]} -eq 0 ]]; then
    echo "No PIDs specified to wait for" >&2
    return 1
  fi

  # Wait for each PID to complete
  for pid in "${pids[@]}"; do
    # Validate PID
    if ! kill -0 "$pid" 2>/dev/null; then
      # Already terminated process
      results+=(255)
      has_failure=1
      continue
    fi

    wait "$pid" 2>/dev/null
    local exit_code=$?
    results+=($exit_code)

    if [[ $exit_code -ne 0 ]]; then
      has_failure=1
    fi
  done

  # Output result array
  echo "${results[@]}"

  return $has_failure
}
