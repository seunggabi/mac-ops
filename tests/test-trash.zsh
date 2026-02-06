#!/bin/zsh
# =============================================================================
# mac-ops: 휴지통 시스템 테스트
# =============================================================================
setopt NO_ERR_EXIT NO_PIPE_FAIL
setopt NULL_GLOB

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

assert_file_not_exists() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [[ ! -e "$1" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print "  [PASS] $2"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print "  [FAIL] $2 (file still exists: $1)"
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
export MAC_OPS_DRY_RUN=false
export MAC_OPS_VERBOSE=false
export MAC_OPS_FORCE=false
export MAC_OPS_SCHEDULED=true
export MAC_OPS_TRASH_RETENTION_HOURS=72

# --- 모듈 로딩 ---
source "${MAC_OPS_ROOT}/lib/core/config.zsh"
source "${MAC_OPS_ROOT}/lib/core/logger.zsh"
source "${MAC_OPS_ROOT}/lib/core/lock.zsh"
source "${MAC_OPS_ROOT}/lib/core/trash.zsh"
source "${MAC_OPS_ROOT}/lib/core/safety.zsh"
source "${MAC_OPS_ROOT}/lib/core/disk.zsh"
source "${MAC_OPS_ROOT}/lib/utils/plist-helper.zsh"
source "${MAC_OPS_ROOT}/lib/utils/format.zsh"

# 디렉토리 초기화
mac_ops_init_dirs

# 테스트용 파일 경로 (TEST_TMPDIR 내에 생성하여 같은 볼륨 보장)
TEST_FILES_DIR="${TEST_TMPDIR}/test-files"
mkdir -p "${TEST_FILES_DIR}"

print "=== mac-ops 휴지통 시스템 테스트 ==="
print ""

# =============================================================================
# test_trash_move
# =============================================================================
print "[TEST] test_trash_move"

# 테스트 파일 생성
echo "test content for trash move" > "${TEST_FILES_DIR}/file1.txt"

mac_ops_trash_move "${TEST_FILES_DIR}/file1.txt" "test-reason" "test-module" 2>/dev/null
local move_exit=$?

assert_exit_code "${move_exit}" "0" "trash_move returns 0"
assert_file_not_exists "${TEST_FILES_DIR}/file1.txt" "original file removed after trash_move"

# trash 디렉토리에 파일이 존재하는지 확인
local trash_target="${MAC_OPS_TRASH_DIR}${TEST_FILES_DIR}/file1.txt"
assert_file_exists "${trash_target}" "file exists in trash directory"

# metadata plist가 생성되었는지 확인
local meta_count
meta_count=$(ls "${MAC_OPS_META_DIR}"/*.plist 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$((meta_count > 0))" "1" "metadata plist file created"

# metadata의 OriginalPath, Status 값 확인
if [[ ${meta_count} -gt 0 ]]; then
    local meta_file
    meta_file=$(ls "${MAC_OPS_META_DIR}"/*.plist 2>/dev/null | head -1)

    local orig_path
    orig_path=$(plutil -extract OriginalPath raw "${meta_file}" 2>/dev/null)
    assert_eq "${orig_path}" "${TEST_FILES_DIR}/file1.txt" "metadata OriginalPath is correct"

    local status_val
    status_val=$(plutil -extract Status raw "${meta_file}" 2>/dev/null)
    assert_eq "${status_val}" "completed" "metadata Status is completed"
fi

print ""

# =============================================================================
# test_trash_restore
# =============================================================================
print "[TEST] test_trash_restore"

# 새 파일 생성 및 trash 이동
echo "test content for restore" > "${TEST_FILES_DIR}/file2.txt"
local file2_abs="${TEST_FILES_DIR}/file2.txt"
mac_ops_trash_move "${file2_abs}" "test-restore" "test-module" 2>/dev/null

# 원래 파일이 사라졌는지 확인
assert_file_not_exists "${file2_abs}" "file removed before restore"

# 복원
mac_ops_trash_restore "${file2_abs}" 2>/dev/null
local restore_exit=$?

assert_exit_code "${restore_exit}" "0" "trash_restore returns 0"
assert_file_exists "${file2_abs}" "file restored to original location"

# metadata가 삭제되었는지 확인 (file2의 hash에 해당하는 meta만)
local file2_hash
file2_hash=$(print -n "${file2_abs}" | shasum -a 256 | cut -d' ' -f1)
local file2_meta_count
file2_meta_count=$(find "${MAC_OPS_META_DIR}" -name "${file2_hash}_*.plist" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "${file2_meta_count}" "0" "metadata removed after restore"

print ""

# =============================================================================
# test_trash_expire
# =============================================================================
print "[TEST] test_trash_expire"

# 새 파일 생성 및 trash 이동
echo "test content for expire" > "${TEST_FILES_DIR}/file3.txt"
local file3_abs="${TEST_FILES_DIR}/file3.txt"
mac_ops_trash_move "${file3_abs}" "test-expire" "test-module" 2>/dev/null

# metadata의 ExpiresAt을 과거 시간으로 수정
local file3_hash
file3_hash=$(print -n "${file3_abs}" | shasum -a 256 | cut -d' ' -f1)
local file3_meta
file3_meta=$(find "${MAC_OPS_META_DIR}" -name "${file3_hash}_*.plist" 2>/dev/null | head -1)

if [[ -n "${file3_meta}" ]]; then
    # 과거 시간으로 설정 (2020-01-01)
    plutil -replace ExpiresAt -string "2020-01-01T00:00:00Z" "${file3_meta}" 2>/dev/null
fi

# trash 파일의 경로 확인
local file3_trash="${MAC_OPS_TRASH_DIR}${file3_abs}"

# expire 실행
mac_ops_trash_expire 2>/dev/null
local expire_exit=$?

assert_exit_code "${expire_exit}" "0" "trash_expire returns 0"
assert_file_not_exists "${file3_trash}" "expired file permanently deleted from trash"

# metadata도 삭제되었는지
local file3_meta_after
file3_meta_after=$(find "${MAC_OPS_META_DIR}" -name "${file3_hash}_*.plist" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "${file3_meta_after}" "0" "metadata removed after expire"

print ""

# =============================================================================
# test_trash_list
# =============================================================================
print "[TEST] test_trash_list"

# 여러 파일을 trash에 넣기
echo "list test 1" > "${TEST_FILES_DIR}/list1.txt"
echo "list test 2" > "${TEST_FILES_DIR}/list2.txt"
mac_ops_trash_move "${TEST_FILES_DIR}/list1.txt" "list-test" "test-module" 2>/dev/null
mac_ops_trash_move "${TEST_FILES_DIR}/list2.txt" "list-test" "test-module" 2>/dev/null

local list_output
list_output=$(mac_ops_trash_list 2>/dev/null)
local list_exit=$?

assert_exit_code "${list_exit}" "0" "trash_list returns 0"
assert_output_contains "${list_output}" "list1.txt" "trash_list output contains list1.txt"
assert_output_contains "${list_output}" "list2.txt" "trash_list output contains list2.txt"

print ""

# =============================================================================
# test_dry_run
# =============================================================================
print "[TEST] test_dry_run"

MAC_OPS_DRY_RUN=true

echo "dry run content" > "${TEST_FILES_DIR}/dryrun.txt"
mac_ops_trash_move "${TEST_FILES_DIR}/dryrun.txt" "dry-test" "test-module" 2>/dev/null
local dry_exit=$?

assert_exit_code "${dry_exit}" "0" "trash_move in dry-run returns 0"
assert_file_exists "${TEST_FILES_DIR}/dryrun.txt" "file still exists in dry-run mode"

MAC_OPS_DRY_RUN=false

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
