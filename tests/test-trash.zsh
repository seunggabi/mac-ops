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

# A plain read (list-trash, status) shows the legacy entry but changes nothing
local migrate_index_sum_before
migrate_index_sum_before=$(shasum "${INDEX_FILE}" 2>/dev/null)
mac_ops_index_read
assert_file_exists "${migrate_plist}" "read-only index read does not migrate (plist kept)"
assert_eq "$(shasum "${INDEX_FILE}" 2>/dev/null)" "${migrate_index_sum_before}" "read-only index read does not write the index"
assert_eq "${_MAC_OPS_IDX_ORIG[${migrate_hash}_20250101120000]}" "/tmp/migrate-test.txt" "read-only index read shows the legacy entry"

# A locked read-modify-write cycle migrates
mac_ops_trash_reconcile 2>/dev/null
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
# Helpers for the reconcile / atomic move tests
# =============================================================================

# Print the index key whose trash_path equals $1 (empty if not indexed)
find_key_by_trash_path() {
    local k
    mac_ops_index_read
    for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
        if [[ "${_MAC_OPS_IDX_TRASH[${k}]}" == "$1" ]]; then
            print -r -- "${k}"
            return 0
        fi
    done
    return 0
}

# Number of entries left in the staging area
staging_entry_count() {
    local -a staged
    staged=("${MAC_OPS_TRASH_DIR}"/.staging/*(DN))
    print -- "${#staged[@]}"
}

# =============================================================================
# test_reconcile_unindexed_entry
# =============================================================================
print "[TEST] test_reconcile_unindexed_entry"

# An indexed entry and, next to it under the same trash parent, an entry that
# is on disk but has no index record
mkdir -p "${TEST_FILES_DIR}/rec"
echo "indexed sibling" > "${TEST_FILES_DIR}/rec/keep.txt"
mac_ops_trash_move "${TEST_FILES_DIR}/rec/keep.txt" "reconcile-test" "test-module" 2>/dev/null

local rec_trash_parent="${MAC_OPS_TRASH_DIR}${TEST_FILES_DIR}/rec"
local rec_keep="${rec_trash_parent}/keep.txt"
local rec_orphan="${rec_trash_parent}/lost-dir"
mkdir -p "${rec_orphan}/sub"
echo "lost content" > "${rec_orphan}/sub/data.txt"

# Stale and fresh temp index files
local stale_tmp="${MAC_OPS_TRASH_DIR}/.index.json.tmp.99999"
local fresh_tmp="${MAC_OPS_TRASH_DIR}/.index.json.tmp.fresh"
echo "{" > "${stale_tmp}"
touch -t 202001010000 "${stale_tmp}"
echo "{" > "${fresh_tmp}"

assert_eq "$(find_key_by_trash_path "${rec_orphan}")" "" "orphan entry is not in the index before reconcile"

mac_ops_trash_reconcile 2>/dev/null
assert_exit_code "$?" "0" "trash_reconcile returns 0"

local rec_key
rec_key=$(find_key_by_trash_path "${rec_orphan}")
TESTS_TOTAL=$((TESTS_TOTAL + 1))
if [[ -n "${rec_key}" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    print "  [PASS] unindexed entry re-indexed by reconcile"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    print "  [FAIL] unindexed entry re-indexed by reconcile"
fi
mac_ops_index_read
assert_eq "${_MAC_OPS_IDX_ORIG[${rec_key}]}" "${TEST_FILES_DIR}/rec/lost-dir" "re-indexed original_path mirrors the trash path"
assert_eq "${_MAC_OPS_IDX_REASON[${rec_key}]}" "reconciled-unindexed" "re-indexed entry is marked as reconciled"
assert_eq "${_MAC_OPS_IDX_SOURCE[${rec_key}]}" "reconcile" "re-indexed entry has source=reconcile in the index"
TESTS_TOTAL=$((TESTS_TOTAL + 1))
if [[ "${_MAC_OPS_IDX_ORIGTIME[${rec_key}]}" == ????-??-??T??:??:??Z ]] && grep -q '"source": "reconcile"' "${INDEX_FILE}"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    print "  [PASS] original change time recorded and source field persisted"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    print "  [FAIL] original change time recorded and source field persisted (original_time: '${_MAC_OPS_IDX_ORIGTIME[${rec_key}]}')"
fi

# Trashed time is the time of discovery (now), and the expiry is retention
# hours after it
local rec_time_epoch rec_expire_epoch rec_now
rec_time_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${_MAC_OPS_IDX_TIME[${rec_key}]}" '+%s' 2>/dev/null)
rec_expire_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${_MAC_OPS_IDX_EXPIRE[${rec_key}]}" '+%s' 2>/dev/null)
rec_now=$(date +%s)
local rec_age=$((rec_now - rec_time_epoch))
TESTS_TOTAL=$((TESTS_TOTAL + 1))
if [[ ${rec_age} -ge 0 && ${rec_age} -lt 120 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    print "  [PASS] re-indexed timestamp is the time of discovery"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    print "  [FAIL] re-indexed timestamp is the time of discovery (age: ${rec_age}s)"
fi
assert_eq "$((rec_expire_epoch - rec_time_epoch))" "$((72 * 3600))" "re-indexed entry expires after the retention period"

assert_file_exists "${rec_orphan}/sub/data.txt" "reconcile deletes nothing"
assert_file_not_exists "${stale_tmp}" "stale temp index file moved out of the trash root"
assert_file_exists "${MAC_OPS_TRASH_DIR}/.index-recovery/.index.json.tmp.99999" "stale temp index file kept in .index-recovery (never deleted)"
assert_file_exists "${fresh_tmp}" "recent temp index file kept"
assert_eq "$(find_key_by_trash_path "${rec_trash_parent}")" "" "parent directory of an indexed entry is not indexed itself"

# Reconcile is idempotent
local rec_count_before=${#_MAC_OPS_IDX_KEYS[@]}
mac_ops_trash_reconcile 2>/dev/null
mac_ops_index_read
assert_eq "${#_MAC_OPS_IDX_KEYS[@]}" "${rec_count_before}" "second reconcile adds nothing"

# Purge before the time has passed: the re-indexed entry must survive
mac_ops_trash_expire 2>/dev/null
assert_file_exists "${rec_orphan}/sub/data.txt" "re-indexed entry is not purged before it expires"

# Once its time has passed it is purged; the unexpired sibling survives
mac_ops_index_read
_MAC_OPS_IDX_EXPIRE[${rec_key}]="2020-01-01T00:00:00Z"
mac_ops_index_write
mac_ops_trash_expire 2>/dev/null
assert_file_not_exists "${rec_orphan}" "re-indexed entry purged once its time has passed"
assert_eq "$(find_key_by_trash_path "${rec_orphan}")" "" "purged entry removed from index"
assert_file_exists "${rec_keep}" "unexpired indexed sibling survives the purge"

# An unindexed entry that LOOKS months old (its change time) must survive the
# purge pass that discovers it: it is stamped now and gets the full retention
functions -c _mac_ops_trash_entry_ctime _orig_mac_ops_trash_entry_ctime
local months_ago=$(( $(date +%s) - 120 * 86400 ))
_mac_ops_trash_entry_ctime() { REPLY="${months_ago}"; return 0 }
local rec_orphan2="${rec_trash_parent}/lost-file.txt"
echo "lost again" > "${rec_orphan2}"
mac_ops_trash_expire 2>/dev/null
functions -c _orig_mac_ops_trash_entry_ctime _mac_ops_trash_entry_ctime
assert_file_exists "${rec_orphan2}" "months-old unindexed entry survives the purge pass that reconciles it"
local rec_key2
rec_key2=$(find_key_by_trash_path "${rec_orphan2}")
mac_ops_index_read
local rec2_expire_epoch rec2_orig_epoch
rec2_expire_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${_MAC_OPS_IDX_EXPIRE[${rec_key2}]}" '+%s' 2>/dev/null)
rec2_orig_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${_MAC_OPS_IDX_ORIGTIME[${rec_key2}]}" '+%s' 2>/dev/null)
local rec2_left=$(( ${rec2_expire_epoch:-0} - $(date +%s) ))
TESTS_TOTAL=$((TESTS_TOTAL + 1))
if [[ -n "${rec_key2}" && ${rec2_left} -gt $((72 * 3600 - 300)) && ${rec2_left} -le $((72 * 3600)) ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    print "  [PASS] months-old unindexed entry now expires about 72h from now"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    print "  [FAIL] months-old unindexed entry now expires about 72h from now (left: ${rec2_left}s)"
fi
assert_eq "${rec2_orig_epoch}" "${months_ago}" "original (months-old) time recorded for information"
assert_eq "${_MAC_OPS_IDX_SOURCE[${rec_key2}]}" "reconcile" "months-old entry marked source=reconcile"

# A second pass before the new expiry keeps it; once its new expiry has
# passed it is purged
mac_ops_trash_expire 2>/dev/null
assert_file_exists "${rec_orphan2}" "re-indexed entry survives later passes before its new expiry"
mac_ops_index_read
_MAC_OPS_IDX_EXPIRE[${rec_key2}]="2020-01-01T00:00:00Z"
mac_ops_index_write
mac_ops_trash_expire 2>/dev/null
assert_file_not_exists "${rec_orphan2}" "re-indexed entry purged only after its new expiry"
assert_file_exists "${rec_keep}" "indexed sibling still survives"

# Even with retention 0 (due immediately) an entry is never purged in the
# pass that discovered it - only in the next one
local rec_orphan4="${rec_trash_parent}/lost-zero.txt"
echo "zero retention" > "${rec_orphan4}"
local saved_retention="${MAC_OPS_TRASH_RETENTION_HOURS}"
MAC_OPS_TRASH_RETENTION_HOURS=0
mac_ops_trash_expire 2>/dev/null
assert_file_exists "${rec_orphan4}" "retention 0: entry survives the pass that reconciles it"
mac_ops_trash_expire 2>/dev/null
MAC_OPS_TRASH_RETENTION_HOURS="${saved_retention}"
assert_file_not_exists "${rec_orphan4}" "retention 0: entry purged by the next pass"

# A re-indexed entry can be restored by its original path
local rec_orphan3="${rec_trash_parent}/restore-me.txt"
echo "bring me back" > "${rec_orphan3}"
mac_ops_trash_reconcile 2>/dev/null
mac_ops_trash_restore "${TEST_FILES_DIR}/rec/restore-me.txt" 2>/dev/null
assert_exit_code "$?" "0" "re-indexed entry can be restored"
assert_file_exists "${TEST_FILES_DIR}/rec/restore-me.txt" "restored re-indexed entry is back at its original path"

rm -f "${fresh_tmp}"
print ""

# =============================================================================
# test_recover_from_temp_index
# =============================================================================
print "[TEST] test_recover_from_temp_index"

# Print one index entry in the on-disk JSON format
# Usage: index_entry_json <key> <original> <trash_path> <timestamp> <expire> [last]
index_entry_json() {
    printf '    "%s": {\n      "original_path": "%s",\n      "trash_path": "%s",\n      "reason": "recover-test",\n      "module": "test-module",\n      "timestamp": "%s",\n      "size_bytes": 7,\n      "expire_after": "%s"\n    }%s\n' \
        "$1" "$2" "$3" "$4" "$5" "${6:-,}"
}

local rv_dir="${MAC_OPS_TRASH_DIR}${TEST_FILES_DIR}/recover"
mkdir -p "${rv_dir}"
echo "recent" > "${rv_dir}/recent.txt"
echo "nearly due" > "${rv_dir}/nearly-due.txt"
local rv_now=$(date +%s)
local rv_recent_iso rv_recent_exp rv_due_iso rv_due_exp
rv_recent_iso=$(date -u -r $((rv_now - 3600)) '+%Y-%m-%dT%H:%M:%SZ')
rv_recent_exp=$(date -u -r $((rv_now - 3600 + 72 * 3600)) '+%Y-%m-%dT%H:%M:%SZ')
rv_due_iso=$(date -u -r $((rv_now - 60 * 3600)) '+%Y-%m-%dT%H:%M:%SZ')
rv_due_exp=$(date -u -r $((rv_now + 12 * 3600)) '+%Y-%m-%dT%H:%M:%SZ')
local rv_hash_recent rv_hash_due
rv_hash_recent=$(print -n "${TEST_FILES_DIR}/recover/recent.txt" | shasum -a 256 | cut -d' ' -f1)
rv_hash_due=$(print -n "${TEST_FILES_DIR}/recover/nearly-due.txt" | shasum -a 256 | cut -d' ' -f1)
local rv_tmp="${MAC_OPS_TRASH_DIR}/.index.json.tmp.recover1"
{
    printf '{\n  "version": 1,\n  "entries": {\n'
    index_entry_json "${rv_hash_recent}_20990101000001" "${TEST_FILES_DIR}/recover/recent.txt" "${rv_dir}/recent.txt" "${rv_recent_iso}" "${rv_recent_exp}"
    index_entry_json "${rv_hash_due}_20990101000002" "${TEST_FILES_DIR}/recover/nearly-due.txt" "${rv_dir}/nearly-due.txt" "${rv_due_iso}" "${rv_due_exp}"
    index_entry_json "deadbeef_20990101000003" "${TEST_FILES_DIR}/recover/gone.txt" "${rv_dir}/gone.txt" "${rv_recent_iso}" "${rv_recent_exp}"
    index_entry_json "deadbeef_20990101000004" "${TEST_FILES_DIR}/rec/keep.txt" "${rec_keep}" "${rv_recent_iso}" "${rv_recent_exp}" ""
    printf '  }\n}\n'
} > "${rv_tmp}"
touch -t 202001010000 "${rv_tmp}"
local rv_count_before
mac_ops_index_read
rv_count_before=${#_MAC_OPS_IDX_KEYS[@]}

mac_ops_trash_reconcile 2>/dev/null
mac_ops_index_read

local rv_k_recent rv_k_due
rv_k_recent=$(find_key_by_trash_path "${rv_dir}/recent.txt")
rv_k_due=$(find_key_by_trash_path "${rv_dir}/nearly-due.txt")
mac_ops_index_read
assert_eq "${rv_k_recent}" "${rv_hash_recent}_20990101000001" "entry recovered from a temp index keeps its key"
assert_eq "${_MAC_OPS_IDX_TIME[${rv_k_recent}]}" "${rv_recent_iso}" "recovered entry with >= 24h left keeps its original trashed time"
assert_eq "${_MAC_OPS_IDX_SOURCE[${rv_k_recent}]}" "recovered" "recovered entry marked source=recovered"
TESTS_TOTAL=$((TESTS_TOTAL + 1))
local rv_due_time_epoch
rv_due_time_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${_MAC_OPS_IDX_TIME[${rv_k_due}]}" '+%s' 2>/dev/null)
if [[ -n "${rv_k_due}" && $(( $(date +%s) - ${rv_due_time_epoch:-0} )) -lt 120 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    print "  [PASS] recovered entry with < 24h left is stamped now"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    print "  [FAIL] recovered entry with < 24h left is stamped now (time: '${_MAC_OPS_IDX_TIME[${rv_k_due}]}')"
fi
assert_eq "${_MAC_OPS_IDX_ORIGTIME[${rv_k_due}]}" "${rv_due_iso}" "re-stamped recovered entry records its original time"
assert_eq "${_MAC_OPS_IDX_SOURCE[${rv_k_due}]}" "reconcile" "re-stamped recovered entry marked source=reconcile"
assert_eq "${_MAC_OPS_IDX_ORIG[deadbeef_20990101000003]+_}" "" "entry no longer on disk is not recovered"
assert_eq "${_MAC_OPS_IDX_ORIG[deadbeef_20990101000004]+_}" "" "entry already indexed is not recovered twice"
assert_eq "${#_MAC_OPS_IDX_KEYS[@]}" "$((rv_count_before + 2))" "exactly the two recoverable entries were added"
assert_file_not_exists "${rv_tmp}" "processed temp index file moved out of the trash root"
assert_file_exists "${MAC_OPS_TRASH_DIR}/.index-recovery/.index.json.tmp.recover1" "processed temp index file kept in .index-recovery"
assert_file_exists "${rv_dir}/recent.txt" "recovery deletes nothing"

# The recovery directory itself is never indexed or purged
mac_ops_trash_expire 2>/dev/null
mac_ops_index_read
local rv_bad=0
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    [[ "${_MAC_OPS_IDX_TRASH[${k}]}" == *"/.index-recovery"* || "${_MAC_OPS_IDX_TRASH[${k}]}" == *"/.index.flock"* ]] && rv_bad=$((rv_bad + 1))
done
assert_eq "${rv_bad}" "0" "bookkeeping files (.index-recovery, .index.flock) are never indexed"
assert_file_exists "${MAC_OPS_TRASH_DIR}/.index-recovery/.index.json.tmp.recover1" "purge keeps .index-recovery"

print ""

# =============================================================================
# test_failed_directory_move_is_all_or_nothing
# =============================================================================
print "[TEST] test_failed_directory_move_is_all_or_nothing"

functions -c _mac_ops_trash_rename _orig_mac_ops_trash_rename
functions -c _mac_ops_trash_copy _orig_mac_ops_trash_copy

local half_src="${TEST_FILES_DIR}/half-dir"
local half_trash="${MAC_OPS_TRASH_DIR}${half_src}"
mkdir -p "${half_src}/nested"
echo "first" > "${half_src}/a.txt"
echo "second" > "${half_src}/nested/b.txt"

# Case 1: rename impossible, copy stops half way but reports success.
# Verification (entry count / size) must catch it.
_mac_ops_trash_rename() { return 1 }
_mac_ops_trash_copy() { mkdir -p "$2" && cp "$1/a.txt" "$2/a.txt"; return 0 }

mac_ops_trash_move "${half_src}" "half-move" "test-module" 2>/dev/null
assert_exit_code "$?" "1" "trash_move fails when the copy is incomplete"
assert_file_exists "${half_src}/a.txt" "source file intact after failed move"
assert_file_exists "${half_src}/nested/b.txt" "nested source file intact after failed move"
assert_file_not_exists "${half_trash}" "no partial copy at the trash path"
assert_eq "$(staging_entry_count)" "0" "no partial copy left in staging"
assert_eq "$(find_key_by_trash_path "${half_trash}")" "" "failed move is not indexed"

# Case 2: the copy itself fails after writing part of the tree
_mac_ops_trash_copy() { mkdir -p "$2" && cp "$1/a.txt" "$2/a.txt"; return 1 }

mac_ops_trash_move "${half_src}" "half-move" "test-module" 2>/dev/null
assert_exit_code "$?" "1" "trash_move fails when the copy errors out"
assert_file_exists "${half_src}/nested/b.txt" "source intact after copy error"
assert_file_not_exists "${half_trash}" "no partial copy at the trash path after copy error"
assert_eq "$(staging_entry_count)" "0" "no partial copy left in staging after copy error"

# Case 3: rename of the source impossible, real copy: verified, then the
# source is removed and the entry indexed
functions -c _orig_mac_ops_trash_copy _mac_ops_trash_copy
_mac_ops_trash_rename() {
    [[ "$1" == "${half_src}" ]] && return 1
    _orig_mac_ops_trash_rename "$@"
}

mac_ops_trash_move "${half_src}" "half-move" "test-module" 2>/dev/null
assert_exit_code "$?" "0" "verified copy fallback succeeds"
assert_file_not_exists "${half_src}" "source removed only after the verified copy"
assert_file_exists "${half_trash}/a.txt" "copied file present in trash"
assert_file_exists "${half_trash}/nested/b.txt" "copied nested file present in trash"
assert_eq "$(staging_entry_count)" "0" "staging is empty after a successful copy"
TESTS_TOTAL=$((TESTS_TOTAL + 1))
if [[ -n "$(find_key_by_trash_path "${half_trash}")" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    print "  [PASS] verified copy is indexed"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    print "  [FAIL] verified copy is indexed"
fi

# Case 4: the source is written to after the verified copy (between the copy
# and the removal of the source): the source must be kept, the trashed copy
# removed and nothing indexed
local late_src="${TEST_FILES_DIR}/late-write-dir"
local late_trash="${MAC_OPS_TRASH_DIR}${late_src}"
mkdir -p "${late_src}"
echo "before copy" > "${late_src}/data.txt"
_mac_ops_trash_rename() {
    [[ "$1" == "${late_src}" ]] && return 1
    _orig_mac_ops_trash_rename "$@" || return 1
    # The staged copy has just been renamed into the trash: write to the source
    [[ "$2" == "${late_trash}"* ]] && echo "written after the copy" > "${late_src}/late.txt"
    return 0
}
local late_out
late_out=$(MAC_OPS_SCHEDULED=false; mac_ops_trash_move "${late_src}" "late-write" "test-module" 2>&1)
assert_exit_code "$?" "1" "cross-volume move fails when the source changed after the copy"
assert_file_exists "${late_src}/late.txt" "late write to the source is kept"
assert_file_exists "${late_src}/data.txt" "source kept when it changed after the copy"
assert_file_not_exists "${late_trash}" "trashed copy removed when the source changed"
assert_eq "$(find_key_by_trash_path "${late_trash}")" "" "changed source is not indexed"
assert_output_contains "${late_out}" "Source changed after it was copied" "late write logs an error"

functions -c _orig_mac_ops_trash_rename _mac_ops_trash_rename

# Same-volume directory move is a rename: the directory inode is preserved
local inode_src="${TEST_FILES_DIR}/inode-dir"
mkdir -p "${inode_src}"
echo "x" > "${inode_src}/x.txt"
local inode_before
inode_before=$(stat -f%i "${inode_src}")
mac_ops_trash_move "${inode_src}" "inode-test" "test-module" 2>/dev/null
assert_eq "$(stat -f%i "${MAC_OPS_TRASH_DIR}${inode_src}" 2>/dev/null)" "${inode_before}" "same-volume directory move is a rename (same inode)"

# Name collision: a second move of the same path gets its own indexed name
mkdir -p "${inode_src}"
echo "y" > "${inode_src}/y.txt"
mac_ops_trash_move "${inode_src}" "inode-test" "test-module" 2>/dev/null
assert_file_exists "${MAC_OPS_TRASH_DIR}${inode_src}/x.txt" "first trashed copy untouched by a name collision"
assert_file_not_exists "${MAC_OPS_TRASH_DIR}${inode_src}/inode-dir" "colliding move is not nested inside the existing entry"
mac_ops_trash_reconcile 2>/dev/null
assert_output_contains "$(mac_ops_trash_list 2>/dev/null)" "inode-test" "colliding entries stay indexed"
mac_ops_index_read
local collide_unindexed=0
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    [[ "${_MAC_OPS_IDX_REASON[${k}]}" == "reconciled-unindexed" && "${_MAC_OPS_IDX_TRASH[${k}]}" == *"inode-dir"* ]] && collide_unindexed=$((collide_unindexed + 1))
done
assert_eq "${collide_unindexed}" "0" "name collision leaves no unindexed entry"

print ""

# =============================================================================
# test_directory_in_use_is_not_moved
# =============================================================================
print "[TEST] test_directory_in_use_is_not_moved"

local busy_src="${TEST_FILES_DIR}/busy-dir"
mkdir -p "${busy_src}"
echo "held open" > "${busy_src}/held.txt"

local busy_fd
exec {busy_fd}<"${busy_src}/held.txt"
rm -f "${MAC_OPS_HOME}/.tmp/open-files.list"

mac_ops_trash_move "${busy_src}" "busy-test" "test-module" 2>/dev/null
assert_exit_code "$?" "1" "directory with a file open in a running process is refused"
assert_file_exists "${busy_src}/held.txt" "in-use directory left untouched"
assert_file_not_exists "${MAC_OPS_TRASH_DIR}${busy_src}" "in-use directory not in trash"

exec {busy_fd}<&-
rm -f "${MAC_OPS_HOME}/.tmp/open-files.list"

mac_ops_trash_move "${busy_src}" "busy-test" "test-module" 2>/dev/null
assert_exit_code "$?" "0" "directory is moved once nothing has it open"
assert_file_exists "${MAC_OPS_TRASH_DIR}${busy_src}/held.txt" "released directory moved to trash"

# A single open file (e.g. a sqlite database) is not moved either
local busy_file="${TEST_FILES_DIR}/busy.sqlite"
echo "SQLite format 3" > "${busy_file}"
exec {busy_fd}<"${busy_file}"
rm -f "${MAC_OPS_HOME}/.tmp/open-files.list"
mac_ops_trash_move "${busy_file}" "busy-test" "test-module" 2>/dev/null
assert_exit_code "$?" "1" "single file open in a running process is refused"
assert_file_exists "${busy_file}" "open single file left untouched"
exec {busy_fd}<&-

# The check fails closed: no lsof, or a failing lsof, means "unknown" and
# nothing is moved
functions -c _mac_ops_lsof_names _orig_mac_ops_lsof_names
local unknown_file="${TEST_FILES_DIR}/unknown-state.txt"
echo "state unknown" > "${unknown_file}"

_mac_ops_lsof_names() { return 127 }
rm -f "${MAC_OPS_HOME}/.tmp/open-files.list"
local unknown_out
unknown_out=$(MAC_OPS_SCHEDULED=false; mac_ops_trash_move "${unknown_file}" "unknown-test" "test-module" 2>&1)
assert_exit_code "$?" "1" "move refused when lsof is missing"
assert_output_contains "${unknown_out}" "cannot tell whether a running process has it open" "missing lsof logs an error"
assert_file_exists "${unknown_file}" "file kept when lsof is missing"

_mac_ops_lsof_names() { print "p123"; return 1 }
rm -f "${MAC_OPS_HOME}/.tmp/open-files.list"
mac_ops_trash_move "${unknown_file}" "unknown-test" "test-module" 2>/dev/null
assert_exit_code "$?" "1" "move refused when lsof fails"
assert_file_exists "${unknown_file}" "file kept when lsof fails"
assert_file_not_exists "${MAC_OPS_HOME}/.tmp/open-files.list" "no open-file cache written from a failed lsof"

functions -c _orig_mac_ops_lsof_names _mac_ops_lsof_names
rm -f "${MAC_OPS_HOME}/.tmp/open-files.list"
mac_ops_trash_move "${unknown_file}" "unknown-test" "test-module" 2>/dev/null
assert_exit_code "$?" "0" "file moved once lsof works and nothing has it open"

print ""

# =============================================================================
# test_index_lock_fails_safe
# =============================================================================
print "[TEST] test_index_lock_fails_safe"

local lock_file="${MAC_OPS_TRASH_DIR}/.index.flock"
: >> "${lock_file}"

# A lock directory left by an older version does not block anything
mkdir -p "${MAC_OPS_TRASH_DIR}/.index.lock"
print -- "999999" > "${MAC_OPS_TRASH_DIR}/.index.lock/pid"

# Lock held by another live process: nothing may be moved or written
/bin/zsh -c 'zmodload zsh/system && zsystem flock "$1" && print held > "$2" && sleep 60' _ "${lock_file}" "${TEST_TMPDIR}/lock-held" &
local holder_pid=$!
local lock_wait=0
while [[ ! -f "${TEST_TMPDIR}/lock-held" && ${lock_wait} -lt 50 ]]; do
    sleep 0.1
    lock_wait=$((lock_wait + 1))
done

echo "locked out" > "${TEST_FILES_DIR}/locked.txt"
local saved_lock_timeout="${MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS}"
MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS=1
mac_ops_trash_move "${TEST_FILES_DIR}/locked.txt" "lock-test" "test-module" 2>/dev/null
assert_exit_code "$?" "1" "trash_move fails instead of writing the index without the lock"
assert_file_exists "${TEST_FILES_DIR}/locked.txt" "source untouched when the lock is unavailable"
mac_ops_index_add "lockfail_1" "/x" "${MAC_OPS_TRASH_DIR}/x" "lock-test" "test-module" "2020-01-01T00:00:00Z" 0 "2099-01-01T00:00:00Z" 2>/dev/null
assert_exit_code "$?" "1" "a live owner's lock cannot be taken (index_add times out)"

# A subshell forked while this process holds the lock does not hold it
kill "${holder_pid}" 2>/dev/null
wait "${holder_pid}" 2>/dev/null
_mac_ops_index_lock
( _mac_ops_index_lock 2>/dev/null; print -- "$?" > "${TEST_TMPDIR}/sub-lock-rc" )
assert_eq "$(cat "${TEST_TMPDIR}/sub-lock-rc")" "1" "forked subshell does not inherit the parent's lock"
_mac_ops_index_unlock

# Owner gone: the kernel released its lock
mac_ops_trash_move "${TEST_FILES_DIR}/locked.txt" "lock-test" "test-module" 2>/dev/null
assert_exit_code "$?" "0" "lock of an exited owner is free again"
MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS="${saved_lock_timeout}"

# Two concurrent writers doing index updates in a loop: no entry is lost
local conc_n=25
for conc_w in a b; do
    (
        local i
        for i in {1..${conc_n}}; do
            mac_ops_index_add "conc_${conc_w}_${i}" "/conc/${conc_w}/${i}" "${MAC_OPS_TRASH_DIR}/conc/${conc_w}/${i}" \
                "concurrency-test" "test-module" "2099-01-01T00:00:00Z" 1 "2099-01-04T00:00:00Z" 2>/dev/null
        done
    ) &
done
wait
mac_ops_index_read
local conc_found=0
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    [[ "${_MAC_OPS_IDX_REASON[${k}]}" == "concurrency-test" ]] && conc_found=$((conc_found + 1))
done
assert_eq "${conc_found}" "$((2 * conc_n))" "two concurrent writers: all $((2 * conc_n)) index updates kept"
# Drop the synthetic entries again
_mac_ops_index_lock
_mac_ops_index_load_locked
local -a conc_keys
conc_keys=()
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    [[ "${_MAC_OPS_IDX_REASON[${k}]}" == "concurrency-test" ]] && conc_keys+=("${k}")
done
_mac_ops_index_forget "${conc_keys[@]}"
mac_ops_index_write
_mac_ops_index_unlock
rm -rf "${MAC_OPS_TRASH_DIR}/.index.lock"

# Parallel moves from subshells (same "$$") must all end up in the index
local par_dir="${TEST_FILES_DIR}/parallel"
mkdir -p "${par_dir}"
local par_i
for par_i in 1 2 3 4 5 6 7 8; do
    echo "p${par_i}" > "${par_dir}/p${par_i}.txt"
done
for par_i in 1 2 3 4 5 6 7 8; do
    ( mac_ops_trash_move "${par_dir}/p${par_i}.txt" "parallel-test" "test-module" 2>/dev/null ) &
done
wait
mac_ops_index_read
local par_indexed=0
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    [[ "${_MAC_OPS_IDX_REASON[${k}]}" == "parallel-test" ]] && par_indexed=$((par_indexed + 1))
done
assert_eq "${par_indexed}" "8" "all 8 parallel moves are indexed"
local -a leftover_tmp
leftover_tmp=("${MAC_OPS_TRASH_DIR}"/.index.json.tmp.*(N))
assert_eq "${#leftover_tmp[@]}" "0" "no temp index files left behind"

print ""

# =============================================================================
# test_dry_run_changes_nothing
# =============================================================================
print "[TEST] test_dry_run_changes_nothing"

# Snapshot: every path under MAC_OPS_HOME (except the log directory) and the
# test source files with size, mtime and mode, plus the index checksum
dry_snapshot() {
    {
        local p
        for p in "${MAC_OPS_HOME}"/**/*(DN) "${TEST_FILES_DIR}"/**/*(DN); do
            [[ "${p}" == "${MAC_OPS_LOG_DIR}"* ]] && continue
            stat -f '%N|%z|%m|%p' "${p}"
        done
        print "dirs: $(stat -f '%m' "${MAC_OPS_HOME}" "${MAC_OPS_TRASH_DIR}" "${TEST_FILES_DIR}" | tr '\n' ' ')"
        print "index: $(shasum < "${INDEX_FILE}")"
    } | LC_ALL=C sort
}

# Fixture: an indexed entry past expiry, an unindexed months-old entry, a
# stale temp index file, a legacy plist, a stale staging leftover, an empty
# directory, no lock file and no open-file cache
echo "expired content" > "${TEST_FILES_DIR}/dry-expired.txt"
mac_ops_trash_move "${TEST_FILES_DIR}/dry-expired.txt" "dry-fixture" "test-module" 2>/dev/null
local dry_expired_trash="${MAC_OPS_TRASH_DIR}${TEST_FILES_DIR}/dry-expired.txt"
mac_ops_index_read
for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
    [[ "${_MAC_OPS_IDX_TRASH[${k}]}" == "${dry_expired_trash}" ]] && _MAC_OPS_IDX_EXPIRE[${k}]="2020-01-01T00:00:00Z"
done
mac_ops_index_write
echo "restore me in dry run" > "${TEST_FILES_DIR}/dry-restore.txt"
mac_ops_trash_move "${TEST_FILES_DIR}/dry-restore.txt" "dry-fixture" "test-module" 2>/dev/null

local dry_unindexed="${MAC_OPS_TRASH_DIR}${TEST_FILES_DIR}/dry-unindexed"
mkdir -p "${dry_unindexed}"
echo "old app data" > "${dry_unindexed}/data.db"
touch -t 202501010000 "${dry_unindexed}/data.db" "${dry_unindexed}"
print '{ "version": 1, "entries": {' > "${MAC_OPS_TRASH_DIR}/.index.json.tmp.dryrun"
touch -t 202001010000 "${MAC_OPS_TRASH_DIR}/.index.json.tmp.dryrun"
mkdir -p "${MAC_OPS_TRASH_DIR}/.staging/copy.dryrun"
touch -t 202001010000 "${MAC_OPS_TRASH_DIR}/.staging/copy.dryrun"
mkdir -p "${MAC_OPS_TRASH_DIR}/empty-leftover"
local dry_plist="${MAC_OPS_META_DIR}/aaaa_20250101000000.plist"
plutil -create xml1 "${dry_plist}" 2>/dev/null
plutil -insert OriginalPath -string "/tmp/dry-legacy.txt" "${dry_plist}" 2>/dev/null
plutil -insert TrashPath -string "${MAC_OPS_TRASH_DIR}/dry-legacy.txt" "${dry_plist}" 2>/dev/null
plutil -insert Status -string "completed" "${dry_plist}" 2>/dev/null
echo "move me in dry run" > "${TEST_FILES_DIR}/dry-move.txt"
rm -f "${MAC_OPS_TRASH_DIR}/.index.flock" "${MAC_OPS_HOME}/.tmp/open-files.list"
rm -rf "${MAC_OPS_TRASH_DIR}/.index.lock"
# config.plist saying DryRun=false must not override --dry-run
plutil -create xml1 "${MAC_OPS_CONFIG_FILE}" 2>/dev/null
plutil -insert DryRun -bool false "${MAC_OPS_CONFIG_FILE}" 2>/dev/null
local dry_home="${TEST_TMPDIR}/dry-home"
mkdir -p "${dry_home}"
sleep 1

local dry_before dry_after dry_log
dry_before=$(dry_snapshot)

MAC_OPS_DRY_RUN=true
dry_log=$(MAC_OPS_SCHEDULED=false
    mac_ops_trash_expire 2>&1
    mac_ops_trash_reconcile 2>&1
    mac_ops_trash_move "${TEST_FILES_DIR}/dry-move.txt" "dry-test" "test-module" 2>&1
    mac_ops_trash_restore "${TEST_FILES_DIR}/dry-restore.txt" 2>&1
    mac_ops_index_add "dry_1" "/x" "${MAC_OPS_TRASH_DIR}/x" "dry" "dry" "2020-01-01T00:00:00Z" 0 "2099-01-01T00:00:00Z" 2>&1
    mac_ops_trash_list 2>&1
    mac_ops_trash_status 2>&1
)
MAC_OPS_DRY_RUN=false
dry_log+=$'\n'$(
    HOME="${dry_home}" MAC_OPS_SCHEDULED=false zsh "${MAC_OPS_ROOT}/bin/mac-ops" purge --dry-run 2>&1
    HOME="${dry_home}" MAC_OPS_SCHEDULED=false zsh "${MAC_OPS_ROOT}/bin/mac-ops" restore "${TEST_FILES_DIR}/dry-restore.txt" --dry-run 2>&1
    HOME="${dry_home}" MAC_OPS_SCHEDULED=false zsh "${MAC_OPS_ROOT}/bin/mac-ops" list-trash 2>&1
    HOME="${dry_home}" MAC_OPS_SCHEDULED=false zsh "${MAC_OPS_ROOT}/bin/mac-ops" status 2>&1
    HOME="${dry_home}" MAC_OPS_SCHEDULED=false zsh "${MAC_OPS_ROOT}/bin/mac-ops" install --dry-run 2>&1
    HOME="${dry_home}" MAC_OPS_SCHEDULED=false zsh "${MAC_OPS_ROOT}/bin/mac-ops" monitor setup --dry-run 2>&1
)
dry_after=$(dry_snapshot)

assert_eq "${dry_after}" "${dry_before}" "dry-run expire/reconcile/purge/move/restore/list/status: file list and index checksum unchanged"
assert_file_exists "${dry_expired_trash}" "dry-run purge deletes nothing"
assert_file_exists "${MAC_OPS_TRASH_DIR}/.index.json.tmp.dryrun" "dry-run leaves temp index files in place"
assert_file_exists "${dry_plist}" "dry-run does not migrate legacy plists"
assert_file_not_exists "${MAC_OPS_TRASH_DIR}/.index.flock" "dry-run creates no lock file"
assert_file_not_exists "${MAC_OPS_HOME}/.tmp/open-files.list" "dry-run writes no open-file cache"
assert_file_exists "${TEST_FILES_DIR}/dry-move.txt" "dry-run move leaves the source"
assert_file_not_exists "${TEST_FILES_DIR}/dry-restore.txt" "dry-run restore moves nothing back"
assert_file_not_exists "${dry_home}/Library/LaunchAgents" "dry-run install / monitor setup write no plist"
assert_output_contains "${dry_log}" "[DRY_RUN] Will permanently delete: ${dry_expired_trash}" "dry-run logs the purge it skips"
assert_output_contains "${dry_log}" "[DRY_RUN] Will re-index unindexed trash entry: ${dry_unindexed}" "dry-run logs the re-index it skips"
assert_output_contains "${dry_log}" "[DRY_RUN] Will move ${MAC_OPS_TRASH_DIR}/.index.json.tmp.dryrun" "dry-run logs the temp-file move it skips"
assert_output_contains "${dry_log}" "[DRY_RUN] Will remove staging leftover" "dry-run logs the staging cleanup it skips"
assert_output_contains "${dry_log}" "[DRY_RUN] Will move to trash: ${TEST_FILES_DIR}/dry-move.txt" "dry-run logs the move it skips"
assert_output_contains "${dry_log}" "[DRY_RUN] Will restore" "dry-run logs the restore it skips"
assert_output_contains "${dry_log}" "[DRY_RUN] Will write the trash index" "dry-run logs the index write it skips"
assert_output_contains "${dry_log}" "[DRY_RUN] Will write ${dry_home}/Library/LaunchAgents/com.mac-ops.cleanup.plist" "dry-run install logs what it skips"

# Clean up the fixture (the real runs below would otherwise act on it)
rm -f "${MAC_OPS_CONFIG_FILE}" "${dry_plist}" "${MAC_OPS_TRASH_DIR}/.index.json.tmp.dryrun" "${TEST_FILES_DIR}/dry-move.txt"
rm -rf "${MAC_OPS_TRASH_DIR}/.staging/copy.dryrun" "${MAC_OPS_TRASH_DIR}/empty-leftover"

print ""

# =============================================================================
# test_agent_bin_path (launchd plist must survive "brew upgrade")
# =============================================================================
print "[TEST] test_agent_bin_path"

# Runs bin/mac-ops as a subprocess with a throwaway HOME. Only the read-only
# "__agent-bin-path" and "status" commands are used; nothing is registered
# with launchd.
local fake_home="${TEST_TMPDIR}/fake-home"
local fake_brew="${TEST_TMPDIR}/fake-brew"
local fake_cellar_bin="${fake_brew}/Cellar/mac-ops/1.4.0/libexec/bin/mac-ops"
mkdir -p "${fake_home}" "${fake_cellar_bin:h}" "${fake_brew}/opt" "${fake_brew}/bin"
print "#!/bin/zsh" > "${fake_cellar_bin}"
chmod +x "${fake_cellar_bin}"

agent_bin_path() {
    HOME="${fake_home}" zsh "${MAC_OPS_ROOT}/bin/mac-ops" __agent-bin-path "$1" 2>/dev/null
}

# Cellar path, stable opt link present -> opt path
ln -s "../Cellar/mac-ops/1.4.0" "${fake_brew}/opt/mac-ops"
assert_eq "$(agent_bin_path "${fake_cellar_bin}")" "${fake_brew}/opt/mac-ops/libexec/bin/mac-ops" "Cellar path maps to the stable opt path"

# The chosen path survives an upgrade that removes the old version
mkdir -p "${fake_brew}/Cellar/mac-ops/1.4.2/libexec/bin"
print "#!/bin/zsh" > "${fake_brew}/Cellar/mac-ops/1.4.2/libexec/bin/mac-ops"
chmod +x "${fake_brew}/Cellar/mac-ops/1.4.2/libexec/bin/mac-ops"
local chosen_path
chosen_path=$(agent_bin_path "${fake_cellar_bin}")
rm -f "${fake_brew}/opt/mac-ops"
ln -s "../Cellar/mac-ops/1.4.2" "${fake_brew}/opt/mac-ops"
rm -rf "${fake_brew}/Cellar/mac-ops/1.4.0"
TESTS_TOTAL=$((TESTS_TOTAL + 1))
if [[ -x "${chosen_path}" && ! -e "${fake_cellar_bin}" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    print "  [PASS] chosen path still resolves after the old version is removed"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    print "  [FAIL] chosen path still resolves after the old version is removed"
fi

# No opt link, wrapper in <prefix>/bin -> wrapper
rm -f "${fake_brew}/opt/mac-ops"
print "#!/bin/zsh" > "${fake_brew}/bin/mac-ops"
chmod +x "${fake_brew}/bin/mac-ops"
assert_eq "$(agent_bin_path "${fake_brew}/Cellar/mac-ops/1.4.2/libexec/bin/mac-ops")" "${fake_brew}/bin/mac-ops" "Cellar path falls back to the prefix wrapper"

# Neither exists -> resolved path unchanged
rm -f "${fake_brew}/bin/mac-ops"
assert_eq "$(agent_bin_path "${fake_brew}/Cellar/mac-ops/1.4.2/libexec/bin/mac-ops")" "${fake_brew}/Cellar/mac-ops/1.4.2/libexec/bin/mac-ops" "Cellar path kept when no stable path exists"

# Not a Homebrew install -> unchanged
assert_eq "$(agent_bin_path "/Users/someone/src/mac-ops/bin/mac-ops")" "/Users/someone/src/mac-ops/bin/mac-ops" "non-Cellar path is kept as is"

# status reports a plist that points at a file that no longer exists
mkdir -p "${fake_home}/Library/LaunchAgents"
sed -e "s|REPLACEME_MAC_OPS_BIN|${fake_cellar_bin}|g" \
    -e "s|REPLACEME_MAC_OPS_HOME|${fake_home}/.mac-ops|g" \
    "${MAC_OPS_ROOT}/launchd/com.mac-ops.monitor.plist" > "${fake_home}/Library/LaunchAgents/com.mac-ops.monitor.plist"
local agent_status
agent_status=$(HOME="${fake_home}" zsh "${MAC_OPS_ROOT}/bin/mac-ops" status 2>/dev/null)
assert_output_contains "${agent_status}" "com.mac-ops.monitor: BROKEN" "status flags a plist pointing at a missing file"
assert_output_contains "${agent_status}" "${fake_cellar_bin}" "status names the missing file"
assert_output_contains "${agent_status}" "Fix: mac-ops monitor unsetup && mac-ops monitor setup" "status prints the exact command that fixes it"

# An existing but versioned Cellar path is flagged too (it breaks on the
# next brew upgrade)
sed -e "s|REPLACEME_MAC_OPS_BIN|${fake_brew}/Cellar/mac-ops/1.4.2/libexec/bin/mac-ops|g" \
    -e "s|REPLACEME_MAC_OPS_HOME|${fake_home}/.mac-ops|g" \
    "${MAC_OPS_ROOT}/launchd/com.mac-ops.cleanup.plist" > "${fake_home}/Library/LaunchAgents/com.mac-ops.cleanup.plist"
agent_status=$(HOME="${fake_home}" zsh "${MAC_OPS_ROOT}/bin/mac-ops" status 2>/dev/null)
assert_output_contains "${agent_status}" "com.mac-ops.cleanup: STALE" "status flags an existing versioned Cellar path"
assert_output_contains "${agent_status}" "Fix: mac-ops uninstall && mac-ops install" "status prints the fix for the cleanup agent"

# Stable (non-Cellar) existing path: OK
print "#!/bin/zsh" > "${fake_brew}/bin/mac-ops"
chmod +x "${fake_brew}/bin/mac-ops"
sed -e "s|REPLACEME_MAC_OPS_BIN|${fake_brew}/bin/mac-ops|g" \
    -e "s|REPLACEME_MAC_OPS_HOME|${fake_home}/.mac-ops|g" \
    "${MAC_OPS_ROOT}/launchd/com.mac-ops.cleanup.plist" > "${fake_home}/Library/LaunchAgents/com.mac-ops.cleanup.plist"
agent_status=$(HOME="${fake_home}" zsh "${MAC_OPS_ROOT}/bin/mac-ops" status 2>/dev/null)
assert_output_contains "${agent_status}" "com.mac-ops.cleanup: OK" "status accepts a plist whose stable target exists"

# The check itself, on a fixture directory (no HOME involved)
local fixture_agents="${TEST_TMPDIR}/fixture-agents"
mkdir -p "${fixture_agents}"
sed -e "s|REPLACEME_MAC_OPS_BIN|/opt/homebrew/Cellar/mac-ops/1.4.0/libexec/bin/mac-ops-missing|g" \
    -e "s|REPLACEME_MAC_OPS_HOME|${fake_home}/.mac-ops|g" \
    "${MAC_OPS_ROOT}/launchd/com.mac-ops.monitor.plist" > "${fixture_agents}/com.mac-ops.monitor.plist"
agent_status=$(zsh -c 'source "$1"; _mac_ops_report_agents "$2"' _ <(sed -n '/^_mac_ops_report_agents()/,/^}/p' "${MAC_OPS_ROOT}/bin/mac-ops") "${fixture_agents}" 2>/dev/null)
assert_output_contains "${agent_status}" "com.mac-ops.monitor: BROKEN" "fixture plist with a missing Cellar program is reported"
assert_output_contains "${agent_status}" "Fix: mac-ops monitor unsetup && mac-ops monitor setup" "fixture report names the fix command"

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
