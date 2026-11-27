#!/bin/zsh
# =============================================================================
# mac-ops: file-cleanup module protection tests (tmp, log, cache, browser, dev)
# Every fixture lives under mktemp -d and every module runs in dry-run mode:
# a "Will move to trash: <path>" line is the only evidence of a move.
# =============================================================================
setopt NO_ERR_EXIT NO_PIPE_FAIL

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
        print "  [FAIL] $3 (output contains: '$2')"
    fi
}

# An item survives when it is not announced as a move and its skip is logged
assert_survives() {
    assert_output_not_contains "$1" "Will move to trash: $2 " "$4 is not moved"
    assert_output_contains "$1" "skipped ($5): $2 (reason: $3" "$4 skip is logged with its reason"
}

assert_moved() {
    assert_output_contains "$1" "Will move to trash: $2 " "$3 is moved"
}

# --- Project root ---
MAC_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Test environment: everything, including HOME, points into the fixture ---
TEST_TMPDIR=$(mktemp -d)
TEST_TMPDIR="${TEST_TMPDIR:A}"
if [[ -z "${TEST_TMPDIR}" || ! -d "${TEST_TMPDIR}" ]]; then
    print "[FAIL] cannot create fixture directory"
    exit 1
fi

export HOME="${TEST_TMPDIR}/home"
export MAC_OPS_HOME="${TEST_TMPDIR}/mac-ops-home"
export MAC_OPS_TRASH_DIR="${MAC_OPS_HOME}/.trash"
export MAC_OPS_META_DIR="${MAC_OPS_HOME}/.metadata"
export MAC_OPS_LOG_DIR="${MAC_OPS_HOME}/.logs"
export MAC_OPS_LOCK_FILE="${MAC_OPS_HOME}/mac-ops.lock"
export MAC_OPS_CONFIG_FILE="${MAC_OPS_HOME}/config.plist"
export MAC_OPS_DRY_RUN=true
export MAC_OPS_VERBOSE=true
export MAC_OPS_FORCE=false
export MAC_OPS_SCHEDULED=false
export MAC_OPS_TRASH_RETENTION_HOURS=72
export MAC_OPS_TMP_DIR="${TEST_TMPDIR}/tmp-root"
export MAC_OPS_VAR_FOLDERS_DIR="${TEST_TMPDIR}/vf"
mkdir -p "${HOME}" "${MAC_OPS_TMP_DIR}" "${MAC_OPS_VAR_FOLDERS_DIR}"

for lib_file in core/config core/logger core/lock core/trash core/safety core/ignore core/disk \
    utils/plist-helper utils/format \
    modules/tmp-cleanup modules/log-cleanup modules/cache-cleanup \
    modules/browser-cleanup modules/dev-cleanup; do
    source "${MAC_OPS_ROOT}/lib/${lib_file}.zsh"
done
mac_ops_init_dirs

# --- Fixture helpers ---
OLD_STAMP=202001010000

# Set mtime and atime of a path and everything below it to an old date
make_old() {
    find "$1" -exec touch -t "${OLD_STAMP}" {} +
}

# The process and open-file lists are seeded so the tests do not depend on
# what happens to run on this machine
seed_running() {
    _MAC_OPS_FC_RUNNING_EXECS="$1"
}
IDLE_PROCESSES="/sbin/launchd
/usr/libexec/logd"
_MAC_OPS_FC_RUNNING_BUNDLES="com.example.running"

print "=== mac-ops file-cleanup protection tests (dry-run) ==="
print ""

# =============================================================================
# Absolute timestamp helper
# =============================================================================
print "[TEST] cutoff_time"

cutoff=$(_mac_ops_fc_cutoff_time 3)
assert_eq "$?" "0" "cutoff_time exits 0"
timestamp_re='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
[[ "${cutoff}" =~ ${timestamp_re} ]]
assert_eq "$?" "0" "cutoff_time prints an absolute timestamp (${cutoff})"

mkdir -p "${TEST_TMPDIR}/stamp"
print "x" > "${TEST_TMPDIR}/stamp/fresh"
found=$(find "${TEST_TMPDIR}/stamp" -type f -newermt "${cutoff}" -print -quit 2>&1)
assert_eq "$?" "0" "find -newermt accepts the timestamp"
assert_eq "${found}" "${TEST_TMPDIR}/stamp/fresh" "find -newermt finds the fresh file"
found=$(/usr/bin/find "${TEST_TMPDIR}/stamp" -type f -newermt "${cutoff}" -print -quit 2>&1)
assert_eq "${found}" "${TEST_TMPDIR}/stamp/fresh" "/usr/bin/find -newermt accepts the timestamp"

_mac_ops_fc_cutoff_time "abc" >/dev/null 2>&1
assert_eq "$?" "1" "cutoff_time rejects a non-numeric threshold"

print ""

# =============================================================================
# A failed recent-use check must not read as "nothing recent"
# =============================================================================
print "[TEST] recent_use_check_fails_closed"

seed_running "${IDLE_PROCESSES}"
_MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder"

mkdir -p "${TEST_TMPDIR}/failcheck/dir"
print "x" > "${TEST_TMPDIR}/failcheck/dir/file"
make_old "${TEST_TMPDIR}/failcheck/dir"

_mac_ops_fc_live_entry "${TEST_TMPDIR}/failcheck/dir" "not a timestamp" >/dev/null
assert_eq "$?" "2" "live_entry reports a failed find as 2, not as 'nothing recent'"
_mac_ops_fc_live_entry "${TEST_TMPDIR}/failcheck/dir" "${cutoff}" >/dev/null
assert_eq "$?" "1" "live_entry reports 1 for an old directory"
_mac_ops_fc_guard "${TEST_TMPDIR}/failcheck/dir" "test" "not a timestamp" >/dev/null 2>&1
assert_eq "$?" "1" "guard protects the item when the check fails"
_mac_ops_fc_guard "${TEST_TMPDIR}/failcheck/dir" "test" "" >/dev/null 2>&1
assert_eq "$?" "1" "guard protects the item when the cutoff is empty"
_mac_ops_fc_guard "${TEST_TMPDIR}/failcheck/dir" "test" "${cutoff}" >/dev/null 2>&1
assert_eq "$?" "0" "guard lets an old, unused directory through"

print ""

# =============================================================================
# Running-process detection by executable path, not by name substring
# =============================================================================
print "[TEST] running_process_detection"

seed_running "/Applications/Notes Board.app/Contents/MacOS/Notes Board --popoutZoom
/usr/local/bin/uvicorn
npm exec some-server@1.0.0"
_mac_ops_fc_exec_running "/zoom.us.app/"
assert_eq "$?" "1" "an app with 'Zoom' in another app's name is not running"
_mac_ops_fc_exec_running "/Notes Board.app/"
assert_eq "$?" "0" "an app is running when its bundle path is in the list"
_mac_ops_fc_tool_running uv uvx
assert_eq "$?" "1" "uvicorn is not uv"
_mac_ops_fc_manager_running npm
assert_eq "$?" "0" "npm is detected through its rewritten process title"

seed_running "/opt/homebrew/bin/uv"
_mac_ops_fc_manager_running uv
assert_eq "$?" "0" "uv is detected by executable name"

print ""

# =============================================================================
# Open-file list from the real lsof: a file held open is reported as open
# =============================================================================
print "[TEST] open_file_detection"

mkdir -p "${TEST_TMPDIR}/openfix/held" "${TEST_TMPDIR}/openfix/idle"
print "x" > "${TEST_TMPDIR}/openfix/held/data"
print "x" > "${TEST_TMPDIR}/openfix/idle/data"
exec {held_fd}<"${TEST_TMPDIR}/openfix/held/data"
_MAC_OPS_FC_OPEN_PATHS=""
_mac_ops_fc_is_open "${TEST_TMPDIR}/openfix/held"
assert_eq "$?" "0" "a directory with a file held open is reported as open"
_mac_ops_fc_is_open "${TEST_TMPDIR}/openfix/idle"
assert_eq "$?" "1" "a directory nobody has open is reported as not open"
exec {held_fd}<&-

print ""

# =============================================================================
# User temp directory (T, C, X under /private/var/folders/*/*)
# =============================================================================
print "[TEST] var_folders_protection"

VF_USER="${MAC_OPS_VAR_FOLDERS_DIR}/ab/cd"
VF_T="${VF_USER}/T"
VF_X="${VF_USER}/X"
mkdir -p "${VF_T}" "${VF_X}" "${VF_USER}/C"

# A socket
zmodload zsh/net/socket
zsocket -l "${VF_T}/s.sock"
socket_fd=${REPLY}
[[ -S "${VF_T}/s.sock" ]]
assert_eq "$?" "0" "fixture socket was created"

# TemporaryItems, com.apple.*, code-sign clone
mkdir -p "${VF_T}/TemporaryItems/inner" "${VF_T}/com.apple.fixture" "${VF_X}/abc123.code_sign_clone/App.app"
print "x" > "${VF_T}/TemporaryItems/inner/file"
print "x" > "${VF_T}/com.apple.fixture/file"
print "x" > "${VF_X}/abc123.code_sign_clone/App.app/binary"

# Old top-level mtime, fresh file inside
mkdir -p "${VF_T}/old-top-fresh-inner/sub"
print "x" > "${VF_T}/old-top-fresh-inner/sub/fresh"
touch -t "${OLD_STAMP}" "${VF_T}/old-top-fresh-inner/sub" "${VF_T}/old-top-fresh-inner"

# Old everywhere, but one file was read recently
mkdir -p "${VF_T}/old-read-recently"
print "x" > "${VF_T}/old-read-recently/file"
make_old "${VF_T}/old-read-recently"
touch -a "${VF_T}/old-read-recently/file"

# A socket inside an old directory
mkdir -p "${VF_T}/old-with-socket"
zsocket -l "${VF_T}/old-with-socket/i.sock"
inner_socket_fd=${REPLY}

# Security software
mkdir -p "${VF_T}/AhnLab-Update"
print "x" > "${VF_T}/AhnLab-Update/file"

# Open in a running process (seeded below)
mkdir -p "${VF_T}/held-open"
print "x" > "${VF_T}/held-open/file"

# Per-app directory of a running app (bundle ID seeded above)
mkdir -p "${VF_USER}/C/com.example.running.helper"
print "x" > "${VF_USER}/C/com.example.running.helper/shader"
make_old "${VF_USER}/C/com.example.running.helper"

# Old directory tree without any file (a daemon's temp root)
mkdir -p "${VF_T}/somedaemond/sub"

# Positive controls: old directory and old file with nothing fresh
mkdir -p "${VF_T}/old-dir/sub"
print "x" > "${VF_T}/old-dir/sub/file"
print "x" > "${VF_T}/old-file.txt"

for fixture in "${VF_T}/s.sock" "${VF_T}/TemporaryItems" "${VF_T}/com.apple.fixture" \
    "${VF_X}/abc123.code_sign_clone" "${VF_T}/old-with-socket" "${VF_T}/AhnLab-Update" \
    "${VF_T}/held-open" "${VF_T}/somedaemond" "${VF_T}/old-dir" "${VF_T}/old-file.txt"; do
    make_old "${fixture}"
done

seed_running "${IDLE_PROCESSES}"
_MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder
n${VF_T}/held-open/file"

vf_output=$(_mac_ops_tmp_clean_var_folders 7 2>&1)

assert_survives "${vf_output}" "${VF_T}/s.sock" "socket" "socket" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/TemporaryItems" "TemporaryItems" "TemporaryItems" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/com.apple.fixture" "com.apple" "com.apple.* item" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_X}/abc123.code_sign_clone" "code-sign clone" "code-sign clone" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/old-top-fresh-inner" "used after" "old directory with a fresh inner file" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/old-read-recently" "used after" "old directory with a recently read file" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/old-with-socket" "socket inside" "old directory with a socket inside" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/AhnLab-Update" "security software path" "security software directory" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/held-open" "open by a running process" "directory open in a process" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_USER}/C/com.example.running.helper" "owning app is running" "per-app directory of a running app" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/somedaemond" "no files inside" "old directory tree without files" "tmp-cleanup"
assert_moved "${vf_output}" "${VF_T}/old-dir" "old directory with nothing fresh"
assert_moved "${vf_output}" "${VF_T}/old-file.txt" "old file"
assert_output_not_contains "${vf_output}" "Will move to trash: ${VF_T}/old-dir/sub" "an old directory is moved as a whole, not file by file"

print ""

# =============================================================================
# /tmp: parked items go, agent scratch directories and sockets stay
# =============================================================================
print "[TEST] tmp_protection"

TMP_ROOT="${MAC_OPS_TMP_DIR}"
mkdir -p "${TMP_ROOT}/claude-501/session/scratchpad" "${TMP_ROOT}/Users/someone/project/dist" \
    "${TMP_ROOT}/Library/parked" "${TMP_ROOT}/.hidden-old"
print "x" > "${TMP_ROOT}/claude-501/session/scratchpad/notes"
print "x" > "${TMP_ROOT}/Users/someone/project/dist/bundle.js"
print "x" > "${TMP_ROOT}/Library/parked/new-file"
print "x" > "${TMP_ROOT}/.hidden-old/file"
make_old "${TMP_ROOT}/claude-501"
make_old "${TMP_ROOT}/Users"
make_old "${TMP_ROOT}/.hidden-old"
touch -t "${OLD_STAMP}" "${TMP_ROOT}/Library"

# The scan root is reached through a symlink, like /tmp -> /private/tmp
ln -s "${TMP_ROOT}" "${TEST_TMPDIR}/tmp-link"

_MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder"
tmp_output=$(_mac_ops_tmp_clean_path "${TEST_TMPDIR}/tmp-link" 3 "tmp-expired" 2>&1)

assert_survives "${tmp_output}" "${TMP_ROOT}/claude-501" "agent scratch directory" "claude-* scratch directory" "tmp-cleanup"
assert_survives "${tmp_output}" "${TMP_ROOT}/Library" "used after" "parked directory with a fresh file" "tmp-cleanup"
assert_moved "${tmp_output}" "${TMP_ROOT}/Users" "old parked directory (scan root given as a symlink)"
assert_moved "${tmp_output}" "${TMP_ROOT}/.hidden-old" "old hidden directory"

# The open-file list cannot be built: nothing may be moved
tmp_output=$(
    _MAC_OPS_FC_OPEN_PATHS=""
    lsof() { return 1 }
    _mac_ops_tmp_clean_path "${TMP_ROOT}" 3 "tmp-expired" 2>&1
)
assert_output_not_contains "${tmp_output}" "Will move to trash" "nothing is moved when the open-file list is unavailable"
assert_output_contains "${tmp_output}" "reason: open-file list unavailable" "the unavailable open-file list is logged"

print ""

# =============================================================================
# Logs: open logs and diagnostic reports newer than 30 days stay
# =============================================================================
print "[TEST] log_protection"

LOGS="${HOME}/Library/Logs"
DIAG="${LOGS}/DiagnosticReports"
mkdir -p "${LOGS}/SomeApp" "${LOGS}/Fortinet" "${DIAG}"
print "x" > "${LOGS}/SomeApp/old.log"
print "x" > "${LOGS}/SomeApp/open.log"
print "x" > "${LOGS}/SomeApp/fresh.log"
print "x" > "${LOGS}/Fortinet/agent.log"
print "x" > "${DIAG}/recent.crash"
print "x" > "${DIAG}/ancient.crash"
touch -t "${OLD_STAMP}" "${LOGS}/SomeApp/old.log" "${LOGS}/SomeApp/open.log" \
    "${LOGS}/Fortinet/agent.log" "${DIAG}/ancient.crash"
touch -t "$(date -v-20d '+%Y%m%d%H%M')" "${DIAG}/recent.crash"

_MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder
n${LOGS}/SomeApp/open.log"

log_output=$(MAC_OPS_DIAG_REPORT_MAX_AGE_DAYS=1; mac_ops_log_cleanup 2>&1)

assert_moved "${log_output}" "${LOGS}/SomeApp/old.log" "old log"
assert_output_not_contains "${log_output}" "Will move to trash: ${LOGS}/SomeApp/fresh.log" "fresh log is not moved"
assert_survives "${log_output}" "${LOGS}/SomeApp/open.log" "open by a running process" "old log open in a running app" "log-cleanup"
assert_survives "${log_output}" "${LOGS}/Fortinet/agent.log" "security software path" "security software log" "log-cleanup"
assert_output_not_contains "${log_output}" "Will move to trash: ${DIAG}/recent.crash" "20-day-old diagnostic report is not moved, even with a 1-day setting"
assert_output_contains "${log_output}" "Will move to trash: ${DIAG}/ancient.crash (reason: diagnostic-report-expired)" "old diagnostic report is moved by the diagnostic pass only"
assert_output_not_contains "${log_output}" "Will move to trash: ${DIAG}/ancient.crash (reason: log-expired)" "the 7-day pass does not scan DiagnosticReports"

print ""

# =============================================================================
# Caches: things that are not caches, running package managers, security software
# =============================================================================
print "[TEST] cache_protection"

CACHES="${HOME}/Library/Caches"
mkdir -p "${CACHES}/ms-playwright/chromium-1" "${CACHES}/JetBrains/IntelliJIdea/index" \
    "${CACHES}/uv/archive" "${CACHES}/pnpm/store" "${CACHES}/com.example.gone/data" \
    "${CACHES}/com.wizvera.agent" "${CACHES}/com.example.held"
for cache_fixture in ms-playwright/chromium-1/chrome JetBrains/IntelliJIdea/index/data uv/archive/pkg \
    pnpm/store/pkg com.example.gone/data/blob com.wizvera.agent/blob com.example.held/blob; do
    print "x" > "${CACHES}/${cache_fixture}"
done
make_old "${CACHES}"

seed_running "${IDLE_PROCESSES}
/opt/homebrew/bin/uv"
_MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder
n${CACHES}/com.example.held/blob"

cache_output=$(mac_ops_cache_cleanup 2>&1)

assert_survives "${cache_output}" "${CACHES}/ms-playwright" "not a disposable cache" "ms-playwright" "cache-cleanup"
assert_survives "${cache_output}" "${CACHES}/JetBrains" "not a disposable cache" "JetBrains" "cache-cleanup"
assert_survives "${cache_output}" "${CACHES}/uv" "uv is running" "uv cache while uv runs" "cache-cleanup"
assert_survives "${cache_output}" "${CACHES}/com.wizvera.agent" "security software path" "security software cache" "cache-cleanup"
assert_survives "${cache_output}" "${CACHES}/com.example.held" "open by a running process" "cache open in a running process" "cache-cleanup"
assert_moved "${cache_output}" "${CACHES}/pnpm" "package manager cache while the manager is not running"
assert_moved "${cache_output}" "${CACHES}/com.example.gone" "old cache of an app that is gone"

print ""

# =============================================================================
# Browser caches are moved only when the browser is not running
# =============================================================================
print "[TEST] browser_protection"

CHROME_BASE="${CACHES}/Google/Chrome/Default"
mkdir -p "${CHROME_BASE}/Cache" "${CHROME_BASE}/Code Cache"
print "x" > "${CHROME_BASE}/Cache/data_0"
print "x" > "${CHROME_BASE}/Code Cache/js"

seed_running "${IDLE_PROCESSES}
/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
browser_output=$(_mac_ops_browser_chrome 2>&1)
assert_output_not_contains "${browser_output}" "Will move to trash" "Chrome cache is not moved while Chrome runs"
assert_output_contains "${browser_output}" "skipped (browser-cleanup): ${CHROME_BASE} (reason: Chrome is running)" "Chrome skip is logged with its reason"

print "x" > "${CHROME_BASE}/Cache/held_by_helper"
_MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder
n${CHROME_BASE}/Cache/held_by_helper"
seed_running "${IDLE_PROCESSES}
/Applications/Some Editor.app/Contents/MacOS/Some Editor --chrome-flag"
browser_output=$(_mac_ops_browser_chrome 2>&1)
assert_survives "${browser_output}" "${CHROME_BASE}/Cache/held_by_helper" "open by a running process" "cache file open in a helper process" "browser-cleanup"
assert_moved "${browser_output}" "${CHROME_BASE}/Cache/data_0" "Chrome cache when Chrome is not running"
assert_moved "${browser_output}" "${CHROME_BASE}/Code Cache/js" "Chrome code cache when Chrome is not running"

print ""

# =============================================================================
# Developer caches: an empty directory must not abort on an unmatched glob
# =============================================================================
print "[TEST] dev_empty_glob"

mkdir -p "${HOME}/Library/Developer/Xcode/Archives"
seed_running "${IDLE_PROCESSES}"
_MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder"
dev_output=$(_mac_ops_dev_xcode 2>&1)
assert_eq "$?" "0" "xcode cleanup returns 0 with an empty Archives directory"
assert_output_not_contains "${dev_output}" "no matches found" "an unmatched glob does not abort the cleanup"

seed_running "${IDLE_PROCESSES}
/Applications/Xcode.app/Contents/MacOS/Xcode"
dev_output=$(_mac_ops_dev_xcode 2>&1)
assert_output_contains "${dev_output}" "skipped (dev-cleanup): Xcode caches (reason: Xcode is running)" "Xcode caches are skipped while Xcode runs"

print ""

# =============================================================================
# Teardown (dry-run only: every fixture must still be in place)
# =============================================================================
print "[TEST] dry_run_left_fixtures_in_place"

[[ -d "${VF_T}/old-dir" && -f "${LOGS}/SomeApp/old.log" && -d "${CACHES}/com.example.gone" ]]
assert_eq "$?" "0" "dry-run moved nothing"

exec {socket_fd}<&-
exec {inner_socket_fd}<&-
rm -rf "${TEST_TMPDIR}"

print ""

# --- Result summary ---
print "========================================="
print "Test results: ${TESTS_PASSED}/${TESTS_TOTAL} passed, ${TESTS_FAILED} failed"
print "========================================="

if [[ ${TESTS_FAILED} -gt 0 ]]; then
    exit 1
fi
exit 0
