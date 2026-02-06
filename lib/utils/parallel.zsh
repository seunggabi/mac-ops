# lib/utils/parallel.zsh
# 병렬 실행 유틸리티

# 여러 함수를 병렬로 실행
# 인자: 함수명 배열 (공백으로 구분)
# 반환: 실패한 함수 목록을 stdout에 출력, 성공 시 0 반환
mac_ops_parallel_run() {
  local -a functions=("$@")
  local -a pids=()
  local -a results=()
  local -a failed=()

  if [[ ${#functions[@]} -eq 0 ]]; then
    echo "실행할 함수가 지정되지 않았습니다" >&2
    return 1
  fi

  # 각 함수를 백그라운드로 실행
  for func in "${functions[@]}"; do
    # 함수 존재 여부 확인
    if ! typeset -f "$func" &>/dev/null; then
      echo "함수가 존재하지 않습니다: $func" >&2
      failed+=("$func")
      continue
    fi

    # 백그라운드 실행
    (
      $func
      exit $?
    ) &

    pids+=($!)
  done

  # 모든 프로세스 완료 대기 및 결과 수집
  local idx=0
  for pid in "${pids[@]}"; do
    wait $pid
    local exit_code=$?
    results+=($exit_code)

    # 실패한 함수 기록
    if [[ $exit_code -ne 0 ]]; then
      failed+=("${functions[$idx]}")
    fi

    ((idx++))
  done

  # 실패한 함수가 있으면 출력
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "${failed[@]}"
    return 1
  fi

  return 0
}

# PID 배열에 대해 완료 대기 및 결과 수집
# 인자: pid 배열
# 반환: exit code 배열을 stdout에 출력 (공백으로 구분), 하나라도 실패하면 1 반환
mac_ops_parallel_wait() {
  local -a pids=("$@")
  local -a results=()
  local has_failure=0

  if [[ ${#pids[@]} -eq 0 ]]; then
    echo "대기할 PID가 지정되지 않았습니다" >&2
    return 1
  fi

  # 각 PID 완료 대기
  for pid in "${pids[@]}"; do
    # PID 유효성 검사
    if ! kill -0 "$pid" 2>/dev/null; then
      # 이미 종료된 프로세스
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

  # 결과 배열 출력
  echo "${results[@]}"

  return $has_failure
}
