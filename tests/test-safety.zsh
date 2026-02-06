#!/bin/zsh
# =============================================================================
# mac-ops: 안전 시스템 테스트
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

assert_file_exists() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [[ -e "$1" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print "  [PASS] $2"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print "  [FAIL] $2 (file not found: $1)"
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
export MAC_OPS_DRY_RUN=false
export MAC_OPS_VERBOSE=false
export MAC_OPS_FORCE=false
export MAC_OPS_SCHEDULED=true

# --- 모듈 로딩 ---
source "${MAC_OPS_ROOT}/lib/core/config.zsh"
source "${MAC_OPS_ROOT}/lib/core/logger.zsh"
source "${MAC_OPS_ROOT}/lib/core/lock.zsh"
source "${MAC_OPS_ROOT}/lib/core/trash.zsh"
source "${MAC_OPS_ROOT}/lib/core/safety.zsh"
source "${MAC_OPS_ROOT}/lib/core/disk.zsh"
source "${MAC_OPS_ROOT}/lib/utils/plist-helper.zsh"
source "${MAC_OPS_ROOT}/lib/utils/format.zsh"

mac_ops_init_dirs

print "=== mac-ops 안전 시스템 테스트 ==="
print ""

# =============================================================================
# test_whitelist
# mac_ops_is_path_safe: 안전하면 0, 보호됨(위험)이면 1
# =============================================================================
print "[TEST] test_whitelist"

# /System/Library/test -> 보호됨 (1)
mac_ops_is_path_safe "/System/Library/test" 2>/dev/null
assert_exit_code "$?" "1" "is_path_safe /System/Library/test returns 1 (protected)"

# /tmp/test -> 안전 (0)
mac_ops_is_path_safe "/tmp/test" 2>/dev/null
assert_exit_code "$?" "0" "is_path_safe /tmp/test returns 0 (safe)"

# ~/Library/Keychains/test -> 보호됨 (1)
mac_ops_is_path_safe "${HOME}/Library/Keychains/test" 2>/dev/null
assert_exit_code "$?" "1" "is_path_safe ~/Library/Keychains/test returns 1 (protected)"

# ~/Library/Caches/test -> 안전 (0) (Caches는 화이트리스트에 없음)
mac_ops_is_path_safe "${HOME}/Library/Caches/test" 2>/dev/null
assert_exit_code "$?" "0" "is_path_safe ~/Library/Caches/test returns 0 (safe)"

# /bin/bash -> 보호됨 (1)
mac_ops_is_path_safe "/bin/bash" 2>/dev/null
assert_exit_code "$?" "1" "is_path_safe /bin/bash returns 1 (protected)"

# /usr/local/bin/test -> 보호됨 (1) (/usr is whitelisted)
mac_ops_is_path_safe "/usr/local/bin/test" 2>/dev/null
assert_exit_code "$?" "1" "is_path_safe /usr/local/bin/test returns 1 (under /usr)"

# ~/Documents/test -> 보호됨 (1)
mac_ops_is_path_safe "${HOME}/Documents/test" 2>/dev/null
assert_exit_code "$?" "1" "is_path_safe ~/Documents/test returns 1 (protected)"

# / -> 보호됨 (1)
mac_ops_is_path_safe "/" 2>/dev/null
assert_exit_code "$?" "1" "is_path_safe / returns 1 (root protected)"

print ""

# =============================================================================
# test_process_protection
# mac_ops_is_process_protected: 보호 프로세스이면 1, 아니면 0
# =============================================================================
print "[TEST] test_process_protection"

# kernel_task -> 보호됨 (return 1)
mac_ops_is_process_protected "kernel_task" 2>/dev/null
assert_exit_code "$?" "1" "is_process_protected kernel_task returns 1 (protected)"

# some_random_app -> 보호 안됨 (return 0)
mac_ops_is_process_protected "some_random_app" 2>/dev/null
assert_exit_code "$?" "0" "is_process_protected some_random_app returns 0 (not protected)"

# launchd -> 보호됨 (return 1)
mac_ops_is_process_protected "launchd" 2>/dev/null
assert_exit_code "$?" "1" "is_process_protected launchd returns 1 (protected)"

# WindowServer -> 보호됨 (return 1)
mac_ops_is_process_protected "WindowServer" 2>/dev/null
assert_exit_code "$?" "1" "is_process_protected WindowServer returns 1 (protected)"

# Finder -> 보호됨 (return 1)
mac_ops_is_process_protected "Finder" 2>/dev/null
assert_exit_code "$?" "1" "is_process_protected Finder returns 1 (protected)"

# my_custom_daemon -> 보호 안됨 (return 0)
mac_ops_is_process_protected "my_custom_daemon" 2>/dev/null
assert_exit_code "$?" "0" "is_process_protected my_custom_daemon returns 0 (not protected)"

print ""

# =============================================================================
# test_size_guard
# mac_ops_check_size_guard: 통과 0, 차단 1
# =============================================================================
print "[TEST] test_size_guard"

# 작은 파일(1KB) 생성
local small_file="${TEST_TMPDIR}/small_file.bin"
dd if=/dev/zero of="${small_file}" bs=1024 count=1 2>/dev/null

# 기본 제한(2GB)에서 작은 파일 -> 통과 (0)
mac_ops_check_size_guard "${small_file}" 2>/dev/null
assert_exit_code "$?" "0" "size_guard: 1KB file passes default 2GB limit"

# MAC_OPS_MAX_SINGLE_FILE_BYTES를 작은 값(100)으로 설정
MAC_OPS_MAX_SINGLE_FILE_BYTES=100

# 1KB 파일 -> 차단 (1)
mac_ops_check_size_guard "${small_file}" 2>/dev/null
assert_exit_code "$?" "1" "size_guard: 1KB file blocked with 100-byte limit"

# MAC_OPS_FORCE=true -> 무시하고 통과 (0)
MAC_OPS_FORCE=true
mac_ops_check_size_guard "${small_file}" 2>/dev/null
assert_exit_code "$?" "0" "size_guard: force mode bypasses limit"

# 원복
MAC_OPS_FORCE=false
MAC_OPS_MAX_SINGLE_FILE_BYTES=2147483648

print ""

# =============================================================================
# test_sip_check
# mac_ops_check_sip: SIP 보호이면 1, 아니면 0
# =============================================================================
print "[TEST] test_sip_check"

# /System -> SIP 보호 (1)
mac_ops_check_sip "/System" 2>/dev/null
assert_exit_code "$?" "1" "check_sip /System returns 1 (SIP protected)"

# /usr/local/bin -> SIP 예외 (0)
mac_ops_check_sip "/usr/local/bin" 2>/dev/null
assert_exit_code "$?" "0" "check_sip /usr/local/bin returns 0 (SIP exception)"

# /tmp -> SIP 아님 (0)
mac_ops_check_sip "/tmp" 2>/dev/null
assert_exit_code "$?" "0" "check_sip /tmp returns 0 (not SIP)"

# /usr/bin -> SIP 보호 (1)
mac_ops_check_sip "/usr/bin" 2>/dev/null
assert_exit_code "$?" "1" "check_sip /usr/bin returns 1 (SIP protected)"

# /bin -> SIP 보호 (1)
mac_ops_check_sip "/bin" 2>/dev/null
assert_exit_code "$?" "1" "check_sip /bin returns 1 (SIP protected)"

# /var/log -> SIP 보호 (1) (/var is SIP protected)
mac_ops_check_sip "/var/log" 2>/dev/null
assert_exit_code "$?" "1" "check_sip /var/log returns 1 (SIP protected)"

# /Applications -> SIP 아님 (0)
mac_ops_check_sip "/Applications" 2>/dev/null
assert_exit_code "$?" "0" "check_sip /Applications returns 0 (not SIP)"

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
