#!/bin/zsh
# =============================================================================
# mac-ops: Trash system tests (JSON index)
# =============================================================================
setopt NO_ERR_EXIT NO_PIPE_FAIL
setopt NULL_GLOB

# --- Test framework ---
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

# --- Project root ---
MAC_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Test environment setup ---
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

# --- Module loading ---
source "${MAC_OPS_ROOT}/lib/core/config.zsh"
source "${MAC_OPS_ROOT}/lib/core/logger.zsh"
source "${MAC_OPS_ROOT}/lib/core/lock.zsh"
source "${MAC_OPS_ROOT}/lib/core/trash.zsh"
source "${MAC_OPS_ROOT}/lib/core/safety.zsh"
source "${MAC_OPS_ROOT}/lib/core/disk.zsh"
source "${MAC_OPS_ROOT}/lib/utils/plist-helper.zsh"
source "${MAC_OPS_ROOT}/lib/utils/format.zsh"

# Directory initialization
mac_ops_init_dirs

# Test file paths (created inside TEST_TMPDIR to guarantee same volume)
TEST_FILES_DIR="${TEST_TMPDIR}/test-files"
mkdir -p "${TEST_FILES_DIR}"

# Index file path for test assertions
INDEX_FILE="${MAC_OPS_TRASH_DIR}/.index.json"

print "=== mac-ops Trash System Tests ==="
print ""

# =============================================================================
# test_trash_move
# =============================================================================
print "[TEST] test_trash_move"

# Create test file
echo "test content for trash move" > "${TEST_FILES_DIR}/file1.txt"

mac_ops_trash_move "${TEST_FILES_DIR}/file1.txt" "test-reason" "test-module" 2>/dev/null
local move_exit=$?

assert_exit_code "${move_exit}" "0" "trash_move returns 0"
assert_file_not_exists "${TEST_FILES_DIR}/file1.txt" "original file removed after trash_move"

# Verify file exists in trash directory
local trash_target="${MAC_OPS_TRASH_DIR}${TEST_FILES_DIR}/file1.txt"
assert_file_exists "${trash_target}" "file exists in trash directory"

# Verify JSON index file was created
assert_file_exists "${INDEX_FILE}" "JSON index file created"

# Verify the index contains the correct original_path
mac_ops_index_read
local found_file1=false
local file1_key=""
local k
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    if [[ "${_MAC_OPS_IDX_ORIG[${k}]}" == "${TEST_FILES_DIR}/file1.txt" ]]; then
        found_file1=true
        file1_key="${k}"
        break
    fi
done
assert_eq "${found_file1}" "true" "index contains OriginalPath for file1"

# Verify index entry fields
if [[ -n "${file1_key}" ]]; then
    assert_eq "${_MAC_OPS_IDX_REASON[${file1_key}]}" "test-reason" "index reason is correct"
    assert_eq "${_MAC_OPS_IDX_MODULE[${file1_key}]}" "test-module" "index module is correct"
fi

print ""

# =============================================================================
# test_trash_restore
# =============================================================================
print "[TEST] test_trash_restore"

# Create new file and move to trash
echo "test content for restore" > "${TEST_FILES_DIR}/file2.txt"
local file2_abs="${TEST_FILES_DIR}/file2.txt"
mac_ops_trash_move "${file2_abs}" "test-restore" "test-module" 2>/dev/null

# Verify original file is removed
assert_file_not_exists "${file2_abs}" "file removed before restore"

# Restore
mac_ops_trash_restore "${file2_abs}" 2>/dev/null
local restore_exit=$?

assert_exit_code "${restore_exit}" "0" "trash_restore returns 0"
assert_file_exists "${file2_abs}" "file restored to original location"

# Verify metadata was removed from index (no entry with file2 path hash)
local file2_hash
file2_hash=$(print -n "${file2_abs}" | shasum -a 256 | cut -d' ' -f1)
mac_ops_index_read
local file2_found=false
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    if [[ "${k}" == "${file2_hash}_"* ]]; then
        file2_found=true
        break
    fi
done
assert_eq "${file2_found}" "false" "index entry removed after restore"

print ""

# =============================================================================
# test_trash_expire
# =============================================================================
print "[TEST] test_trash_expire"

# Create new file and move to trash
echo "test content for expire" > "${TEST_FILES_DIR}/file3.txt"
local file3_abs="${TEST_FILES_DIR}/file3.txt"
mac_ops_trash_move "${file3_abs}" "test-expire" "test-module" 2>/dev/null

# Modify expire_after to a past time directly in the JSON index
local file3_hash
file3_hash=$(print -n "${file3_abs}" | shasum -a 256 | cut -d' ' -f1)

# Read index, find the key, change expire, write back
mac_ops_index_read
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    if [[ "${k}" == "${file3_hash}_"* ]]; then
        _MAC_OPS_IDX_EXPIRE[${k}]="2020-01-01T00:00:00Z"
        break
    fi
done
mac_ops_index_write

# Verify trash file path
local file3_trash="${MAC_OPS_TRASH_DIR}${file3_abs}"

# Execute expire
mac_ops_trash_expire 2>/dev/null
local expire_exit=$?

assert_exit_code "${expire_exit}" "0" "trash_expire returns 0"
assert_file_not_exists "${file3_trash}" "expired file permanently deleted from trash"

# Verify metadata was removed from index
mac_ops_index_read
local file3_found=false
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    if [[ "${k}" == "${file3_hash}_"* ]]; then
        file3_found=true
        break
    fi
done
assert_eq "${file3_found}" "false" "index entry removed after expire"

print ""

# =============================================================================
# test_trash_list
# =============================================================================
print "[TEST] test_trash_list"

# Move multiple files to trash
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
# test_trash_status
# =============================================================================
print "[TEST] test_trash_status"

local status_output
status_output=$(mac_ops_trash_status 2>/dev/null)
local status_exit=$?

assert_exit_code "${status_exit}" "0" "trash_status returns 0"
assert_output_contains "${status_output}" "Total items:" "status output contains Total items"
assert_output_contains "${status_output}" "Total size:" "status output contains Total size"

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
# test_plist_migration
# =============================================================================
print "[TEST] test_plist_migration"

# Create a legacy plist metadata file to test migration
local migrate_hash="abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
local migrate_plist="${MAC_OPS_META_DIR}/${migrate_hash}_20250101120000.plist"
mkdir -p "${MAC_OPS_META_DIR}"

# Create a fake trash file for the migration test
local migrate_trash_path="${MAC_OPS_TRASH_DIR}/migrate-test.txt"
echo "migrated content" > "${migrate_trash_path}"

plutil -create xml1 "${migrate_plist}" 2>/dev/null
plutil -insert OriginalPath -string "/tmp/migrate-test.txt" "${migrate_plist}" 2>/dev/null
plutil -insert TrashPath -string "${migrate_trash_path}" "${migrate_plist}" 2>/dev/null
plutil -insert MovedAt -string "2025-01-01T12:00:00Z" "${migrate_plist}" 2>/dev/null
plutil -insert ExpiresAt -string "2025-01-04T12:00:00Z" "${migrate_plist}" 2>/dev/null
plutil -insert SizeBytes -integer 100 "${migrate_plist}" 2>/dev/null
plutil -insert Reason -string "migration-test" "${migrate_plist}" 2>/dev/null
plutil -insert Module -string "test-module" "${migrate_plist}" 2>/dev/null
plutil -insert Status -string "completed" "${migrate_plist}" 2>/dev/null

# Trigger migration by reading the index
mac_ops_index_read

# Verify the plist file was removed
assert_file_not_exists "${migrate_plist}" "legacy plist removed after migration"

# Verify the entry exists in the JSON index
local migrate_key="${migrate_hash}_20250101120000"
local migrate_found=false
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    if [[ "${k}" == "${migrate_key}" ]]; then
        migrate_found=true
        break
    fi
done
assert_eq "${migrate_found}" "true" "migrated entry found in JSON index"

# Verify migrated field values
if [[ "${migrate_found}" == "true" ]]; then
    assert_eq "${_MAC_OPS_IDX_ORIG[${migrate_key}]}" "/tmp/migrate-test.txt" "migrated original_path is correct"
    assert_eq "${_MAC_OPS_IDX_REASON[${migrate_key}]}" "migration-test" "migrated reason is correct"
fi

print ""

# =============================================================================
# Test cleanup
# =============================================================================
rm -rf "${TEST_TMPDIR}"

# --- Results summary ---
print "========================================="
print "Test results: ${TESTS_PASSED}/${TESTS_TOTAL} passed, ${TESTS_FAILED} failed"
print "========================================="

if [[ ${TESTS_FAILED} -gt 0 ]]; then
    exit 1
fi
exit 0
