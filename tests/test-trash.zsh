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

# Trashed time comes from the entry's change time (i.e. about now), and the
# expiry is retention hours after it
local rec_time_epoch rec_expire_epoch rec_now
rec_time_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${_MAC_OPS_IDX_TIME[${rec_key}]}" '+%s' 2>/dev/null)
rec_expire_epoch=$(date -u -jf '%Y-%m-%dT%H:%M:%SZ' "${_MAC_OPS_IDX_EXPIRE[${rec_key}]}" '+%s' 2>/dev/null)
rec_now=$(date +%s)
local rec_age=$((rec_now - rec_time_epoch))
TESTS_TOTAL=$((TESTS_TOTAL + 1))
if [[ ${rec_age} -ge 0 && ${rec_age} -lt 120 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    print "  [PASS] re-indexed timestamp is the entry's change time"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    print "  [FAIL] re-indexed timestamp is the entry's change time (age: ${rec_age}s)"
fi
assert_eq "$((rec_expire_epoch - rec_time_epoch))" "$((72 * 3600))" "re-indexed entry expires after the retention period"

assert_file_exists "${rec_orphan}/sub/data.txt" "reconcile deletes nothing"
assert_file_not_exists "${stale_tmp}" "stale temp index file removed"
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

# A single purge pass picks up an unindexed entry and expires it by its own
# change time (retention 0 = already due)
local rec_orphan2="${rec_trash_parent}/lost-file.txt"
echo "lost again" > "${rec_orphan2}"
local saved_retention="${MAC_OPS_TRASH_RETENTION_HOURS}"
MAC_OPS_TRASH_RETENTION_HOURS=0
mac_ops_trash_expire 2>/dev/null
MAC_OPS_TRASH_RETENTION_HOURS="${saved_retention}"
assert_file_not_exists "${rec_orphan2}" "purge reconciles first: due unindexed entry is purged"
assert_file_exists "${rec_keep}" "indexed sibling still survives"

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

print ""

# =============================================================================
# test_index_lock_fails_safe
# =============================================================================
print "[TEST] test_index_lock_fails_safe"

# Lock held by another live process: nothing may be moved or written
sleep 60 &
local holder_pid=$!
mkdir "${MAC_OPS_TRASH_DIR}/.index.lock"
print -- "${holder_pid}" > "${MAC_OPS_TRASH_DIR}/.index.lock/pid"

echo "locked out" > "${TEST_FILES_DIR}/locked.txt"
local saved_lock_timeout="${MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS}"
MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS=1
mac_ops_trash_move "${TEST_FILES_DIR}/locked.txt" "lock-test" "test-module" 2>/dev/null
assert_exit_code "$?" "1" "trash_move fails instead of writing the index without the lock"
assert_file_exists "${TEST_FILES_DIR}/locked.txt" "source untouched when the lock is unavailable"
assert_file_exists "${MAC_OPS_TRASH_DIR}/.index.lock/pid" "a live owner's lock is not broken"

# Owner dies: the lock is stale and gets taken over
kill "${holder_pid}" 2>/dev/null
wait "${holder_pid}" 2>/dev/null
mac_ops_trash_move "${TEST_FILES_DIR}/locked.txt" "lock-test" "test-module" 2>/dev/null
assert_exit_code "$?" "0" "stale lock of a dead owner is taken over"
assert_file_not_exists "${MAC_OPS_TRASH_DIR}/.index.lock" "lock released after the move"
MAC_OPS_INDEX_LOCK_TIMEOUT_SECONDS="${saved_lock_timeout}"

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
assert_output_contains "${agent_status}" "Fix: mac-ops monitor setup" "status prints the command that fixes it"

sed -e "s|REPLACEME_MAC_OPS_BIN|${fake_brew}/Cellar/mac-ops/1.4.2/libexec/bin/mac-ops|g" \
    -e "s|REPLACEME_MAC_OPS_HOME|${fake_home}/.mac-ops|g" \
    "${MAC_OPS_ROOT}/launchd/com.mac-ops.cleanup.plist" > "${fake_home}/Library/LaunchAgents/com.mac-ops.cleanup.plist"
agent_status=$(HOME="${fake_home}" zsh "${MAC_OPS_ROOT}/bin/mac-ops" status 2>/dev/null)
assert_output_contains "${agent_status}" "com.mac-ops.cleanup: OK" "status accepts a plist whose target exists"

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
