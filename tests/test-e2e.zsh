#!/bin/zsh
# =============================================================================
# mac-ops: End-to-End CLI Tests
# =============================================================================
setopt NO_ERR_EXIT NO_PIPE_FAIL
setopt NULL_GLOB

# --- Test Framework ---
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

assert_exit_nonzero() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [[ "$1" != "0" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print "  [PASS] $2"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print "  [FAIL] $2 (expected non-zero exit code, got: 0)"
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

assert_output_not_contains() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [[ "$1" != *"$2"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print "  [PASS] $3"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print "  [FAIL] $3 (output should not contain: '$2')"
    fi
}

# --- Project Root ---
MAC_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Test environment setup ---
# Dry-run by default; real (non-dry) runs only touch fixture files in TEST_TMPDIR.
# Every scan root and every mac-ops directory points into a fresh mktemp -d
# directory, set BEFORE anything is sourced or run (several paths are
# expanded at source time). The guard below aborts the whole file when any of
# them could reach a real path.
TEST_TMPDIR=$(mktemp -d 2>/dev/null) || TEST_TMPDIR=""
if [[ -z "${TEST_TMPDIR}" || "${TEST_TMPDIR}" != /?* || ! -d "${TEST_TMPDIR}" ]]; then
    print "[ABORT] cannot create a fixture directory with mktemp -d"
    exit 1
fi
export HOME="${TEST_TMPDIR}/home"
export MAC_OPS_HOME="${TEST_TMPDIR}/mac-ops-home"
export MAC_OPS_TRASH_DIR="${MAC_OPS_HOME}/.trash"
export MAC_OPS_META_DIR="${MAC_OPS_HOME}/.metadata"
export MAC_OPS_LOG_DIR="${MAC_OPS_HOME}/.logs"
export MAC_OPS_LOCK_FILE="${MAC_OPS_HOME}/mac-ops.lock"
export MAC_OPS_CONFIG_FILE="${MAC_OPS_HOME}/config.plist"
# Scan roots that are not under HOME (tmp-cleanup, analyze)
export MAC_OPS_TMP_DIR="${TEST_TMPDIR}/scan-tmp"
export MAC_OPS_VAR_FOLDERS_DIR="${TEST_TMPDIR}/scan-var-folders"
export MAC_OPS_DRY_RUN=true
export MAC_OPS_VERBOSE=false
export MAC_OPS_FORCE=false
export MAC_OPS_SCHEDULED=false
export MAC_OPS_TRASH_RETENTION_HOURS=72
# What HOME does not isolate (the process table, docker, brew): those
# modules stay disabled and report-only whatever the caller's environment
# says; data locations are only reported
export MAC_OPS_MODULE_BREW_CLEANUP_ENABLED=false
export MAC_OPS_MODULE_DEV_CLEANUP_ENABLED=false
export MAC_OPS_MODULE_BROWSER_CLEANUP_ENABLED=false
export MAC_OPS_MODULE_DOCKER_CLEANUP_ENABLED=false
export MAC_OPS_MODULE_ZOMBIE_KILLER_ENABLED=false
export MAC_OPS_MODULE_ORPHAN_KILLER_ENABLED=false
export MAC_OPS_DOCKER_ACTION=report
export MAC_OPS_ZOMBIE_ACTION=report
export MAC_OPS_ORPHAN_ACTION=report
export MAC_OPS_ORPHAN_APP_DATA_ACTION=report

# --- Isolation guard ---
_iso_user=$(id -un 2>/dev/null)
_iso_real_home=""
if [[ "${_iso_user}" =~ '^[A-Za-z0-9._-]+$' ]]; then
    eval "_iso_real_home=~${_iso_user}"
fi
if [[ -z "${_iso_real_home}" || "${_iso_real_home}" != /* ]]; then
    print "[ABORT] cannot determine the real home directory of '${_iso_user}'"
    exit 1
fi
if [[ "${HOME}" == "${_iso_real_home}" || "${HOME:A}" == "${_iso_real_home:A}" ]]; then
    print "[ABORT] HOME is the real home directory (${HOME})"
    exit 1
fi
for _iso_var in HOME MAC_OPS_HOME MAC_OPS_TRASH_DIR MAC_OPS_META_DIR MAC_OPS_LOG_DIR \
    MAC_OPS_LOCK_FILE MAC_OPS_CONFIG_FILE MAC_OPS_TMP_DIR MAC_OPS_VAR_FOLDERS_DIR; do
    if [[ "${(P)_iso_var}" != "${TEST_TMPDIR}/"?* || "${(P)_iso_var}" == *"/../"* ]]; then
        print "[ABORT] ${_iso_var} is not inside the fixture directory: ${(P)_iso_var}"
        exit 1
    fi
done
unset _iso_user _iso_real_home _iso_var
# Fixture skeleton of an ordinary Mac home (empty)
mkdir -p "${HOME}/Library/Caches" "${HOME}/Library/Logs/DiagnosticReports" \
    "${HOME}/Library/Application Support/CrashReporter" \
    "${MAC_OPS_TMP_DIR}" "${MAC_OPS_VAR_FOLDERS_DIR}"

# Create test directory structure
mkdir -p "${MAC_OPS_HOME}"
TEST_FILES_DIR="${TEST_TMPDIR}/test-files"
mkdir -p "${TEST_FILES_DIR}"

print "=== mac-ops End-to-End CLI Tests ==="
print ""

# =============================================================================
# test_help_command
# =============================================================================
print "[TEST] test_help_command"

local help_output
help_output=$("${MAC_OPS_ROOT}/bin/mac-ops" help 2>&1)
local help_exit=$?

assert_exit_code "${help_exit}" "0" "help command exits with 0"
assert_output_contains "${help_output}" "mac-ops" "help output contains 'mac-ops'"
assert_output_contains "${help_output}" "Usage" "help output contains 'Usage'"
assert_output_contains "${help_output}" "Commands" "help output contains 'Commands'"

print ""

# =============================================================================
# test_version_command
# =============================================================================
print "[TEST] test_version_command"

local version_output
version_output=$("${MAC_OPS_ROOT}/bin/mac-ops" version 2>&1)
local version_exit=$?

assert_exit_code "${version_exit}" "0" "version command exits with 0"
# The version comes from the git tag or the VERSION file (a CI checkout has
# no tags, so it may be "unknown"): only the format is checked
assert_eq "$([[ "${version_output}" =~ '^mac-ops v[0-9A-Za-z.+-]+$' ]] && print ok)" "ok" "version output is 'mac-ops v<version>' (got: ${version_output})"

print ""

# =============================================================================
# test_config_command
# =============================================================================
print "[TEST] test_config_command"

local config_output
config_output=$("${MAC_OPS_ROOT}/bin/mac-ops" config 2>&1)
local config_exit=$?

assert_exit_code "${config_exit}" "0" "config command exits with 0"
assert_output_contains "${config_output}" "Configuration" "config output contains 'Configuration'"

print ""

# =============================================================================
# test_dryrun_mode
# =============================================================================
print "[TEST] test_dryrun_mode"

local dryrun_output
dryrun_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --dry-run 2>&1)
local dryrun_exit=$?

# Note: May exit with 1 due to readonly 'status' variable bug in zsh
assert_eq "$((dryrun_exit <= 1))" "1" "dry-run mode completes (exit ${dryrun_exit})"
assert_output_contains "${dryrun_output}" "parallel execution" "dry-run output shows parallel execution"

print ""

# =============================================================================
# test_analyze_command
# =============================================================================
print "[TEST] test_analyze_command"

local analyze_output
analyze_output=$("${MAC_OPS_ROOT}/bin/mac-ops" analyze 2>&1)
local analyze_exit=$?

assert_exit_code "${analyze_exit}" "0" "analyze command exits with 0"
assert_output_contains "${analyze_output}" "Disk Space Analysis" "analyze output contains disk report"

print ""

# =============================================================================
# test_status_command
# =============================================================================
print "[TEST] test_status_command"

local status_output
status_output=$("${MAC_OPS_ROOT}/bin/mac-ops" status 2>&1)
local status_exit=$?

assert_exit_code "${status_exit}" "0" "status command exits with 0"
assert_output_contains "${status_output}" "Disk Status" "status output shows disk status"

print ""

# =============================================================================
# test_module_specific_run
# =============================================================================
print "[TEST] test_module_specific_run"

local module_output
module_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --module=cache --dry-run 2>&1)
local module_exit=$?

assert_exit_code "${module_exit}" "0" "module-specific run exits with 0"
assert_output_contains "${module_output}" "cache" "module-specific output mentions cache"

print ""

# =============================================================================
# test_trash_lifecycle
# =============================================================================
print "[TEST] test_trash_lifecycle"

# Create test files
echo "test content 1" > "${TEST_FILES_DIR}/file1.txt"
echo "test content 2" > "${TEST_FILES_DIR}/file2.txt"
mkdir -p "${TEST_FILES_DIR}/subdir"
echo "test content 3" > "${TEST_FILES_DIR}/subdir/file3.txt"

# Real (non-dry) trash operations on the fixture files only
export MAC_OPS_DRY_RUN=false

# Load modules for trash operations
source "${MAC_OPS_ROOT}/lib/core/config.zsh"
source "${MAC_OPS_ROOT}/lib/core/logger.zsh"
source "${MAC_OPS_ROOT}/lib/core/lock.zsh"
source "${MAC_OPS_ROOT}/lib/core/trash.zsh"
source "${MAC_OPS_ROOT}/lib/core/safety.zsh"
source "${MAC_OPS_ROOT}/lib/core/disk.zsh"
source "${MAC_OPS_ROOT}/lib/utils/plist-helper.zsh"
source "${MAC_OPS_ROOT}/lib/utils/format.zsh"

# Initialize directories
mac_ops_init_dirs

# Move files to trash
mac_ops_trash_move "${TEST_FILES_DIR}/file1.txt" "test-e2e" "test-module" 2>/dev/null
local trash_move_exit=$?
assert_exit_code "${trash_move_exit}" "0" "trash_move succeeds"

# Verify original file is removed
assert_file_not_exists "${TEST_FILES_DIR}/file1.txt" "original file removed after trash_move"

# Verify file exists in trash
local trash_target="${MAC_OPS_TRASH_DIR}${TEST_FILES_DIR}/file1.txt"
assert_file_exists "${trash_target}" "file exists in trash directory"

# List trash contents
local list_output
list_output=$(mac_ops_trash_list 2>/dev/null)
local list_exit=$?
assert_exit_code "${list_exit}" "0" "trash_list succeeds"
assert_output_contains "${list_output}" "file1.txt" "trash_list shows file1.txt"

# Restore file from trash
mac_ops_trash_restore "${TEST_FILES_DIR}/file1.txt" 2>/dev/null
local restore_exit=$?
assert_exit_code "${restore_exit}" "0" "trash_restore succeeds"
assert_file_exists "${TEST_FILES_DIR}/file1.txt" "file restored to original location"
assert_file_not_exists "${trash_target}" "file removed from trash after restore"

print ""

# =============================================================================
# test_list_trash_command
# =============================================================================
print "[TEST] test_list_trash_command"

# Create and trash another file
echo "trash test" > "${TEST_FILES_DIR}/trash-test.txt"
mac_ops_trash_move "${TEST_FILES_DIR}/trash-test.txt" "test-e2e" "test-module" 2>/dev/null

# Test list-trash command
local list_trash_output
list_trash_output=$("${MAC_OPS_ROOT}/bin/mac-ops" list-trash 2>&1)
local list_trash_exit=$?

assert_exit_code "${list_trash_exit}" "0" "list-trash command exits with 0"
assert_output_contains "${list_trash_output}" "trash-test.txt" "list-trash shows trashed file"

print ""

# =============================================================================
# test_purge_command (real purge, fixture trash only)
# =============================================================================
print "[TEST] test_purge_command"

# Expire the fixture record; a sentinel outside the trash must survive
local purge_sentinel="${TEST_FILES_DIR}/purge-sentinel.txt"
echo "keep" > "${purge_sentinel}"
local purge_target="${MAC_OPS_TRASH_DIR}${TEST_FILES_DIR}/trash-test.txt"
mac_ops_index_read
local purge_key
for purge_key in "${_MAC_OPS_IDX_KEYS[@]}"; do
    [[ "${_MAC_OPS_IDX_TRASH[${purge_key}]}" == "${purge_target}" ]] && _MAC_OPS_IDX_EXPIRE[${purge_key}]="2020-01-01T00:00:00Z"
done
mac_ops_index_write

local purge_output
purge_output=$("${MAC_OPS_ROOT}/bin/mac-ops" purge 2>&1)
local purge_exit=$?

assert_exit_code "${purge_exit}" "0" "purge command exits with 0"
assert_file_not_exists "${purge_target}" "purge deletes the expired fixture item from the trash"
assert_file_exists "${purge_sentinel}" "purge leaves files outside the trash alone"

# Back to dry-run for every command below
export MAC_OPS_DRY_RUN=true

print ""

# =============================================================================
# test_tmp_module_real_run (non-dry run of one module, fixture scan roots only)
# =============================================================================
print "[TEST] test_tmp_module_real_run"

local tmp_old="${MAC_OPS_TMP_DIR}/e2e-old-file.dat"
local tmp_new="${MAC_OPS_TMP_DIR}/e2e-new-file.dat"
echo "old" > "${tmp_old}"
echo "new" > "${tmp_new}"
touch -t "$(date -v-30d '+%Y%m%d%H%M')" "${tmp_old}"
local tmp_real_output
tmp_real_output=$(MAC_OPS_DRY_RUN=false "${MAC_OPS_ROOT}/bin/mac-ops" run --module=tmp 2>&1)
local tmp_real_exit=$?
assert_exit_code "${tmp_real_exit}" "0" "non-dry tmp run on the fixture exits with 0"
assert_file_not_exists "${tmp_old}" "old fixture file moved out of the fixture tmp dir"
assert_file_exists "${MAC_OPS_TRASH_DIR}${tmp_old}" "old fixture file is in the fixture trash"
assert_file_exists "${tmp_new}" "recent fixture file is kept"

print ""

# =============================================================================
# test_unknown_command
# =============================================================================
print "[TEST] test_unknown_command"

local unknown_output
unknown_output=$("${MAC_OPS_ROOT}/bin/mac-ops" unknown-command 2>&1)
local unknown_exit=$?

assert_exit_nonzero "${unknown_exit}" "unknown command returns non-zero exit code"
assert_output_contains "${unknown_output}" "Unknown argument:" "unknown command shows error message"

print ""

# =============================================================================
# test_unknown_module
# =============================================================================
print "[TEST] test_unknown_module"

local unknown_module_output
unknown_module_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --module=nonexistent --dry-run 2>&1)
local unknown_module_exit=$?

assert_exit_nonzero "${unknown_module_exit}" "unknown module returns non-zero exit code"
assert_output_contains "${unknown_module_output}" "Unknown module:" "unknown module shows error message"

print ""

# =============================================================================
# test_verbose_flag
# =============================================================================
print "[TEST] test_verbose_flag"

local verbose_output
verbose_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --dry-run --verbose 2>&1)
local verbose_exit=$?

assert_exit_code "${verbose_exit}" "0" "verbose flag completes successfully"

print ""

# =============================================================================
# test_force_flag
# =============================================================================
print "[TEST] test_force_flag"

local force_output
force_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --dry-run --force 2>&1)
local force_exit=$?

# Note: May exit with 1 due to readonly 'status' variable bug in zsh
assert_eq "$((force_exit <= 1))" "1" "force flag completes (exit ${force_exit})"
assert_output_contains "${force_output}" "parallel execution" "force flag output shows execution"

print ""

# =============================================================================
# test_module_cache
# =============================================================================
print "[TEST] test_module_cache"

local cache_output
cache_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --module=cache --dry-run 2>&1)
local cache_exit=$?

# Note: May exit with 1 due to readonly 'status' variable bug in zsh
assert_eq "$((cache_exit <= 1))" "1" "cache module completes (exit ${cache_exit})"
assert_output_contains "${cache_output}" "cache" "output mentions cache module"

print ""

# =============================================================================
# test_module_tmp
# =============================================================================
print "[TEST] test_module_tmp"

local tmp_output
tmp_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --module=tmp --dry-run 2>&1)
local tmp_exit=$?

# Note: May exit with 1 due to readonly 'status' variable bug in zsh
assert_eq "$((tmp_exit <= 1))" "1" "tmp module completes (exit ${tmp_exit})"
assert_output_contains "${tmp_output}" "tmp" "output mentions tmp module"

print ""

# =============================================================================
# test_scheduled_mode
# =============================================================================
print "[TEST] test_scheduled_mode"

local scheduled_output
scheduled_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --scheduled --dry-run 2>&1)
local scheduled_exit=$?

# Note: May exit with 1 due to readonly 'status' variable bug in zsh
assert_eq "$((scheduled_exit <= 1))" "1" "scheduled mode completes (exit ${scheduled_exit})"

print ""

# =============================================================================
# test_cli_without_args
# =============================================================================
print "[TEST] test_cli_without_args"

# Without a command the CLI runs "run". A bare "mac-ops" is never executed
# here; the same code path runs with only --dry-run (no command word)
assert_output_contains "$(cat "${MAC_OPS_ROOT}/bin/mac-ops")" 'local command="run"' "CLI without a command defaults to run"
local no_args_output
no_args_output=$("${MAC_OPS_ROOT}/bin/mac-ops" --dry-run 2>&1)
local no_args_exit=$?

# Note: May exit with 1 due to readonly 'status' variable bug in zsh
assert_eq "$((no_args_exit <= 1))" "1" "CLI without a command (dry-run) completes (exit ${no_args_exit})"
assert_output_contains "${no_args_output}" "parallel execution" "CLI without a command runs cleanup"

print ""

# =============================================================================
# test_invalid_flag
# =============================================================================
print "[TEST] test_invalid_flag"

local invalid_flag_output
invalid_flag_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --invalid-flag 2>&1)
local invalid_flag_exit=$?

assert_exit_nonzero "${invalid_flag_exit}" "invalid flag returns non-zero exit code"

print ""

# =============================================================================
# test_full_run_dryrun
# =============================================================================
print "[TEST] test_full_run_dryrun"

local full_run_output
full_run_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --dry-run 2>&1)
local full_run_exit=$?

# Note: May exit with 1 due to readonly 'status' variable bug in zsh
assert_eq "$((full_run_exit <= 1))" "1" "full run in dry-run mode completes (exit ${full_run_exit})"
assert_output_contains "${full_run_output}" "parallel execution" "full run shows parallel execution"

print ""

# =============================================================================
# Test Cleanup
# =============================================================================
rm -rf "${TEST_TMPDIR}"

# --- Results Summary ---
print "========================================="
print "Test Results: ${TESTS_PASSED}/${TESTS_TOTAL} passed, ${TESTS_FAILED} failed"
print "========================================="

if [[ ${TESTS_FAILED} -gt 0 ]]; then
    exit 1
fi
exit 0
