#!/bin/zsh
# =============================================================================
# mac-ops: 모듈 통합 테스트 (dry-run 모드)
# =============================================================================
setopt NO_ERR_EXIT NO_PIPE_FAIL

# --- 테스트 프레임워크 ---
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

assert_eq() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [[ "$1" == "$2" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print "  [PASS] $3"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print "  [FAIL] $3 (expected: '$2', got: '$1')"
    fi
}

assert_exit_code() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [[ "$1" == "$2" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print "  [PASS] $3"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print "  [FAIL] $3 (expected exit code: '$2', got: '$1')"
    fi
}

assert_output_contains() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [[ "$1" == *"$2"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print "  [PASS] $3"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print "  [FAIL] $3 (output does not contain: '$2')"
    fi
}

# --- 프로젝트 루트 ---
MAC_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- 테스트 환경 설정 ---
TEST_TMPDIR=$(mktemp -d)
export MAC_OPS_HOME="${TEST_TMPDIR}/mac-ops-home"
export MAC_OPS_TRASH_DIR="${MAC_OPS_HOME}/.trash"
export MAC_OPS_META_DIR="${MAC_OPS_HOME}/.metadata"
export MAC_OPS_LOG_DIR="${MAC_OPS_HOME}/.logs"
export MAC_OPS_LOCK_FILE="${MAC_OPS_HOME}/mac-ops.lock"
export MAC_OPS_CONFIG_FILE="${MAC_OPS_HOME}/config.plist"
export MAC_OPS_DRY_RUN=true
export MAC_OPS_VERBOSE=false
export MAC_OPS_FORCE=false
export MAC_OPS_SCHEDULED=true
export MAC_OPS_TRASH_RETENTION_HOURS=72

print "=== mac-ops 모듈 통합 테스트 (dry-run) ==="
print ""

# =============================================================================
# 전체 모듈 로딩 테스트
# =============================================================================
print "[TEST] module_loading"

local load_error=0

source "${MAC_OPS_ROOT}/lib/core/config.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/core/logger.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/core/lock.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/core/trash.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/core/safety.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/core/disk.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/utils/plist-helper.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/utils/format.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/utils/parallel.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/cache-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/tmp-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/log-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/zombie-killer.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/orphan-killer.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/orphan-app-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/brew-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/dev-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/docker-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/browser-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/analyze.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/utils/notify.zsh" 2>/dev/null || load_error=1

assert_exit_code "${load_error}" "0" "all modules load without error"

# 디렉토리 초기화
mac_ops_init_dirs

# 전역 카운터 초기화
MAC_OPS_CLEANED_COUNT=0
MAC_OPS_CLEANED_BYTES=0
MAC_OPS_KILLED_COUNT=0

print ""

# =============================================================================
# test_cache_cleanup_dryrun
# =============================================================================
print "[TEST] test_cache_cleanup_dryrun"

mac_ops_cache_cleanup 2>/dev/null
assert_exit_code "$?" "0" "cache_cleanup in dry-run completes without error"

print ""

# =============================================================================
# test_tmp_cleanup_dryrun
# =============================================================================
print "[TEST] test_tmp_cleanup_dryrun"

mac_ops_tmp_cleanup 2>/dev/null
assert_exit_code "$?" "0" "tmp_cleanup in dry-run completes without error"

print ""

# =============================================================================
# test_log_cleanup_dryrun
# =============================================================================
print "[TEST] test_log_cleanup_dryrun"

mac_ops_log_cleanup 2>/dev/null
assert_exit_code "$?" "0" "log_cleanup in dry-run completes without error"

print ""

# =============================================================================
# test_zombie_killer_dryrun
# =============================================================================
print "[TEST] test_zombie_killer_dryrun"

mac_ops_zombie_killer 2>/dev/null
assert_exit_code "$?" "0" "zombie_killer in dry-run completes without error"

print ""

# =============================================================================
# test_orphan_killer_dryrun
# =============================================================================
print "[TEST] test_orphan_killer_dryrun"

mac_ops_orphan_killer 2>/dev/null
assert_exit_code "$?" "0" "orphan_killer in dry-run completes without error"

print ""

# =============================================================================
# test_orphan_app_cleanup_dryrun
# =============================================================================
print "[TEST] test_orphan_app_cleanup_dryrun"

mac_ops_orphan_app_cleanup 2>/dev/null
local orphan_app_exit=$?
# orphan_app_cleanup may return 1 if no bundles collected, which is OK
assert_eq "$((orphan_app_exit <= 1))" "1" "orphan_app_cleanup in dry-run completes (exit ${orphan_app_exit})"

print ""

# =============================================================================
# test_brew_cleanup_dryrun
# =============================================================================
print "[TEST] test_brew_cleanup_dryrun"

mac_ops_brew_cleanup 2>/dev/null
local brew_exit=$?
# brew may not be installed; either 0 (success/skipped) or 1 (cache not found) is acceptable
assert_eq "$((brew_exit <= 1))" "1" "brew_cleanup in dry-run completes (exit ${brew_exit})"

print ""

# =============================================================================
# test_dev_cleanup_dryrun
# =============================================================================
print "[TEST] test_dev_cleanup_dryrun"

mac_ops_dev_cleanup 2>/dev/null
assert_exit_code "$?" "0" "dev_cleanup in dry-run completes without error"

print ""

# =============================================================================
# test_docker_cleanup_dryrun
# =============================================================================
print "[TEST] test_docker_cleanup_dryrun"

mac_ops_docker_cleanup 2>/dev/null
local docker_exit=$?
# docker may not be running; 0 is expected (skipped or dry-run preview)
assert_eq "$((docker_exit <= 1))" "1" "docker_cleanup in dry-run completes (exit ${docker_exit})"

print ""

# =============================================================================
# test_browser_cleanup_dryrun
# =============================================================================
print "[TEST] test_browser_cleanup_dryrun"

mac_ops_browser_cleanup 2>/dev/null
assert_exit_code "$?" "0" "browser_cleanup in dry-run completes without error"

print ""

# =============================================================================
# test_analyze
# =============================================================================
print "[TEST] test_analyze"

local analyze_output
analyze_output=$(mac_ops_analyze 2>/dev/null)
assert_exit_code "$?" "0" "analyze completes without error"
assert_output_contains "${analyze_output}" "Total Reclaimable Space" "analyze output contains total summary"

print ""

# =============================================================================
# test_notify
# =============================================================================
print "[TEST] test_notify"

# scheduled 모드에서 notify_completion 호출 (정리 항목 0이면 알림 안 함)
MAC_OPS_SCHEDULED=true
mac_ops_notify_completion "0" "0" "0" 2>/dev/null
assert_exit_code "$?" "0" "notify_completion with zero items returns 0"

# 정리 항목이 있으면 알림 시도 (osascript 실패해도 return 0)
mac_ops_notify_completion "5" "1048576" "2" 2>/dev/null
assert_exit_code "$?" "0" "notify_completion with items returns 0"

print ""

# =============================================================================
# test_cli_analyze
# =============================================================================
print "[TEST] test_cli_analyze"

local cli_analyze_output
cli_analyze_output=$("${MAC_OPS_ROOT}/bin/mac-ops" analyze 2>&1)
local cli_analyze_exit=$?

assert_exit_code "${cli_analyze_exit}" "0" "bin/mac-ops analyze exits 0"
assert_output_contains "${cli_analyze_output}" "Total Reclaimable Space" "analyze CLI output contains total summary"

print ""

# =============================================================================
# test_cli_help
# =============================================================================
print "[TEST] test_cli_help"

local help_output
help_output=$("${MAC_OPS_ROOT}/bin/mac-ops" help 2>&1)
local help_exit=$?

assert_exit_code "${help_exit}" "0" "bin/mac-ops help exits 0"
assert_output_contains "${help_output}" "mac-ops" "help output contains 'mac-ops'"

print ""

# =============================================================================
# test_cli_version
# =============================================================================
print "[TEST] test_cli_version"

local version_output
version_output=$("${MAC_OPS_ROOT}/bin/mac-ops" version 2>&1)
local version_exit=$?

assert_exit_code "${version_exit}" "0" "bin/mac-ops version exits 0"
assert_output_contains "${version_output}" "mac-ops v" "version output contains 'mac-ops v'"

print ""

# =============================================================================
# test_cli_dryrun
# =============================================================================
print "[TEST] test_cli_dryrun"

local dryrun_output
dryrun_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --dry-run 2>&1)
local dryrun_exit=$?

assert_exit_code "${dryrun_exit}" "0" "bin/mac-ops run --dry-run exits 0"

print ""

# =============================================================================
# 테스트 정리
# =============================================================================
rm -rf "${TEST_TMPDIR}"

# --- 결과 요약 ---
print "========================================="
print "테스트 결과: ${TESTS_PASSED}/${TESTS_TOTAL} passed, ${TESTS_FAILED} failed"
print "========================================="

if [[ ${TESTS_FAILED} -gt 0 ]]; then
    exit 1
fi
exit 0
