#!/bin/zsh
# Test timeout mechanism for parallel execution

# Don't use set -e since tests return non-zero exit codes
# set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_RUN=0
TESTS_PASSED=0

# Load utilities
SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/../lib/utils/parallel.zsh"

# Override timeout for faster testing
MAC_OPS_PARALLEL_TIMEOUT_SECONDS=3

test_assert() {
  local description="$1"
  local condition="$2"

  TESTS_RUN=$((TESTS_RUN + 1))

  if eval "$condition"; then
    echo -e "${GREEN}✓${NC} ${description}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    return 0
  else
    echo -e "${RED}✗${NC} ${description}"
    return 1
  fi
}

# Test 1: Fast completing task should succeed
echo -e "\n${YELLOW}Test 1: Fast completing task${NC}"
fast_task() {
  sleep 1
  return 0
}

(
  fast_task &
  pid=$!
  mac_ops_parallel_wait_with_timeout 5 $pid
  exit $?
) &>/dev/null
result=$?

test_assert "Fast task completes successfully" "[[ $result -eq 0 ]]"

# Test 2: Slow task should timeout
echo -e "\n${YELLOW}Test 2: Slow task times out${NC}"
slow_task() {
  sleep 10
  return 0
}

(
  slow_task &
  pid=$!
  mac_ops_parallel_wait_with_timeout 2 $pid 2>/dev/null
  exit $?
)
result=$?

test_assert "Slow task times out and returns error" "[[ $result -eq 1 ]]"

# Test 3: Multiple tasks with mixed completion
echo -e "\n${YELLOW}Test 3: Multiple tasks with mixed completion${NC}"
task_fast() {
  sleep 1
  return 0
}

task_medium() {
  sleep 2
  return 0
}

(
  task_fast &
  pid1=$!
  task_medium &
  pid2=$!

  mac_ops_parallel_wait_with_timeout 5 $pid1 $pid2
  exit $?
) &>/dev/null
result=$?

test_assert "Multiple fast tasks complete successfully" "[[ $result -eq 0 ]]"

# Test 4: Multiple tasks where one times out
echo -e "\n${YELLOW}Test 4: Multiple tasks where one times out${NC}"
(
  sleep 1 &
  pid1=$!
  sleep 10 &
  pid2=$!

  mac_ops_parallel_wait_with_timeout 2 $pid1 $pid2 2>/dev/null
  exit $?
)
result=$?

test_assert "Mixed timeout scenario returns error" "[[ $result -eq 1 ]]"

# Test 5: Empty PID list
echo -e "\n${YELLOW}Test 5: Empty PID list${NC}"
(
  mac_ops_parallel_wait_with_timeout 5 2>/dev/null
  exit $?
)
result=$?

test_assert "Empty PID list returns error" "[[ $result -eq 1 ]]"

# Test 6: Task that fails before timeout
echo -e "\n${YELLOW}Test 6: Task that fails before timeout${NC}"
failing_task() {
  sleep 1
  return 42
}

(
  failing_task &
  pid=$!
  mac_ops_parallel_wait_with_timeout 5 $pid 2>/dev/null
  exit $?
)
result=$?

test_assert "Failing task returns error" "[[ $result -eq 1 ]]"

# Summary
echo -e "\n${YELLOW}==================${NC}"
echo -e "Tests run: ${TESTS_RUN}"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}$((TESTS_RUN - TESTS_PASSED))${NC}"
echo -e "${YELLOW}==================${NC}\n"

if [[ ${TESTS_PASSED} -eq ${TESTS_RUN} ]]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
fi
