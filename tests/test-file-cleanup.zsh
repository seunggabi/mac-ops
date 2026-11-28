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
    utils/plist-helper utils/format utils/security-keywords utils/running \
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
# User temp directory (/private/var/folders/*/*): the candidates are main's
# (old regular files up to depth 6); protections only remove candidates
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

# Old file next to a fresh one in the same top-level directory
mkdir -p "${VF_T}/old-top-fresh-inner/sub"
print "x" > "${VF_T}/old-top-fresh-inner/old"
print "x" > "${VF_T}/old-top-fresh-inner/sub/fresh"
touch -t "${OLD_STAMP}" "${VF_T}/old-top-fresh-inner/old" "${VF_T}/old-top-fresh-inner/sub" "${VF_T}/old-top-fresh-inner"

# Old everywhere, but one file was read recently
mkdir -p "${VF_T}/old-read-recently"
print "x" > "${VF_T}/old-read-recently/file"
print "x" > "${VF_T}/old-read-recently/other"
make_old "${VF_T}/old-read-recently"
touch -a "${VF_T}/old-read-recently/file"

# A socket inside an old directory
mkdir -p "${VF_T}/old-with-socket"
print "x" > "${VF_T}/old-with-socket/old"
zsocket -l "${VF_T}/old-with-socket/i.sock"
inner_socket_fd=${REPLY}

# Security software
mkdir -p "${VF_T}/AhnLab-Update"
print "x" > "${VF_T}/AhnLab-Update/file"

# Open in a running process (seeded below)
mkdir -p "${VF_T}/held-open"
print "x" > "${VF_T}/held-open/file"
print "x" > "${VF_T}/held-open/other"

# Per-app directory of a running app (bundle ID seeded above)
mkdir -p "${VF_USER}/C/com.example.running.helper"
print "x" > "${VF_USER}/C/com.example.running.helper/shader"
make_old "${VF_USER}/C/com.example.running.helper"

# Positive controls: old file in an old directory, old top-level file,
# old file in C (main scanned C as well)
mkdir -p "${VF_T}/old-dir/sub" "${VF_USER}/C/org.sample.gone"
print "x" > "${VF_T}/old-dir/sub/file"
print "x" > "${VF_T}/old-file.txt"
print "x" > "${VF_USER}/C/org.sample.gone/blob"

for fixture in "${VF_T}/s.sock" "${VF_T}/TemporaryItems" "${VF_T}/com.apple.fixture" \
    "${VF_X}/abc123.code_sign_clone" "${VF_T}/old-with-socket" "${VF_T}/AhnLab-Update" \
    "${VF_T}/held-open" "${VF_T}/old-dir" "${VF_T}/old-file.txt" "${VF_USER}/C/org.sample.gone"; do
    make_old "${fixture}"
done

seed_running "${IDLE_PROCESSES}"
_MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder
n${VF_T}/held-open/file"

vf_output=$(_mac_ops_tmp_clean_var_folders 7 2>&1)

assert_output_not_contains "${vf_output}" "Will move to trash: ${VF_T}/s.sock " "socket is not a candidate"
assert_survives "${vf_output}" "${VF_T}/TemporaryItems/inner/file" "TemporaryItems" "file in TemporaryItems" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/com.apple.fixture/file" "com.apple" "file in a com.apple.* item" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_X}/abc123.code_sign_clone/App.app/binary" "code-sign clone" "file in a code-sign clone" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/old-top-fresh-inner/old" "top-level item" "old file next to a fresh file" "tmp-cleanup"
assert_output_contains "${vf_output}" "skipped (tmp-cleanup): ${VF_T}/old-top-fresh-inner (reason: used after" "the fresh file is the logged reason"
assert_survives "${vf_output}" "${VF_T}/old-read-recently/other" "top-level item" "old file next to a recently read file" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/old-with-socket/old" "top-level item" "old file next to a socket" "tmp-cleanup"
assert_output_contains "${vf_output}" "skipped (tmp-cleanup): ${VF_T}/old-with-socket (reason: socket inside" "the inner socket is the logged reason"
assert_survives "${vf_output}" "${VF_T}/AhnLab-Update/file" "top-level item" "security software file" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_T}/held-open/other" "top-level item" "file next to a file open in a process" "tmp-cleanup"
assert_survives "${vf_output}" "${VF_USER}/C/com.example.running.helper/shader" "top-level item ${VF_USER}/C/com.example.running.helper: owning app is running" "file of a running app" "tmp-cleanup"
assert_moved "${vf_output}" "${VF_T}/old-dir/sub/file" "old file in an old directory"
assert_moved "${vf_output}" "${VF_T}/old-file.txt" "old top-level file"
assert_moved "${vf_output}" "${VF_USER}/C/org.sample.gone/blob" "old file in C of an app that is not running"
assert_output_not_contains "${vf_output}" "Will move to trash: ${VF_T}/old-dir " "a directory is never moved as a whole"
assert_output_not_contains "${vf_output}" "Will move to trash: ${VF_USER}/C/org.sample.gone " "a C directory is never moved as a whole"

print ""

# =============================================================================
# Main's candidate set: a deep old file under a top-level folder that also
# holds a nested com.apple.* directory. Only what main's find selects may be
# announced, the nested com.apple.* cache stays, the folder is never moved.
# =============================================================================
print "[TEST] var_folders_keeps_main_candidate_set"

CAND_ROOT="${TEST_TMPDIR}/vf-cand"
CAND_APP="${CAND_ROOT}/zz/yy/C/org.sample.editor"
mkdir -p "${CAND_APP}/sub" "${CAND_APP}/com.apple.metal/16777235_402" "${CAND_APP}/a/b/c"
print "x" > "${CAND_APP}/sub/old-deep"                          # depth 6: main selects it
print "x" > "${CAND_APP}/com.apple.metal/libraries.data"        # depth 6: main selects it
print "x" > "${CAND_APP}/com.apple.metal/16777235_402/shader"   # depth 7: beyond main's find
print "x" > "${CAND_APP}/a/b/c/too-deep"                        # depth 8: beyond main's find
make_old "${CAND_ROOT}"

main_candidates=$(/usr/bin/find "${CAND_ROOT}" -maxdepth 6 -type f -mtime +7 -user "${USER}" 2>/dev/null | sort)
cand_output=$(MAC_OPS_VAR_FOLDERS_DIR="${CAND_ROOT}"; _mac_ops_tmp_clean_var_folders 7 2>&1)
announced=$(print -r -- "${cand_output}" | sed -n 's/.*Will move to trash: \(.*\) (reason: .*/\1/p' | sort)

extra=$(comm -13 <(print -r -- "${main_candidates}") <(print -r -- "${announced}"))
assert_eq "${extra}" "" "every announced move is one of main's find candidates"
assert_eq "${announced}" "${CAND_APP}/sub/old-deep" "only the deep old file is moved"
assert_survives "${cand_output}" "${CAND_APP}/com.apple.metal/libraries.data" "com.apple" "file in a nested com.apple.* directory" "tmp-cleanup"
assert_output_not_contains "${cand_output}" "Will move to trash: ${CAND_APP} " "the top-level folder is never moved"
assert_output_not_contains "${cand_output}" "Will move to trash: ${CAND_APP}/com.apple.metal " "the nested com.apple.* directory is never moved"
assert_output_not_contains "${cand_output}" "too-deep" "a file beyond main's depth is not a candidate"

print ""

# =============================================================================
# Running-app set: fails closed, matches bundle ID, vendor prefix and app name
# =============================================================================
print "[TEST] running_app_set"

APP_ROOT="${TEST_TMPDIR}/vf-app"
for app_dir in Telegram com.example.vendor.other com.unrelated.thing; do
    mkdir -p "${APP_ROOT}/zz/yy/C/${app_dir}"
    print "x" > "${APP_ROOT}/zz/yy/C/${app_dir}/blob"
done
make_old "${APP_ROOT}"

# lsappinfo fails: the set cannot be built, so nothing may be moved
app_output=$(
    MAC_OPS_VAR_FOLDERS_DIR="${APP_ROOT}"
    _MAC_OPS_FC_RUNNING_BUNDLES=""
    _MAC_OPS_FC_RUNNING_APPS_STATE=""
    lsappinfo() { return 1 }
    _mac_ops_tmp_clean_var_folders 7 2>&1
)
assert_output_not_contains "${app_output}" "Will move to trash" "nothing is moved when the running-app list cannot be built"
assert_output_contains "${app_output}" "com.unrelated.thing: running-app list unavailable" "the unavailable running-app list is logged"

# The process list fails: same
app_output=$(
    MAC_OPS_VAR_FOLDERS_DIR="${APP_ROOT}"
    _MAC_OPS_FC_RUNNING_EXECS=""
    _MAC_OPS_FC_RUNNING_APPS_STATE=""
    ps() { return 1 }
    _mac_ops_tmp_clean_var_folders 7 2>&1
)
assert_output_not_contains "${app_output}" "Will move to trash" "nothing is moved when the process list cannot be built"

# App name from the executable path, vendor prefix from a running bundle ID
app_output=$(
    MAC_OPS_VAR_FOLDERS_DIR="${APP_ROOT}"
    _MAC_OPS_FC_RUNNING_BUNDLES="com.example.vendor-app.main"
    _MAC_OPS_FC_RUNNING_APPS_STATE=""
    seed_running "${IDLE_PROCESSES}
/Applications/Telegram.app/Contents/MacOS/Telegram"
    _mac_ops_tmp_clean_var_folders 7 2>&1
)
assert_survives "${app_output}" "${APP_ROOT}/zz/yy/C/Telegram/blob" "top-level item ${APP_ROOT}/zz/yy/C/Telegram: owning app is running" "folder named after a running app" "tmp-cleanup"
assert_survives "${app_output}" "${APP_ROOT}/zz/yy/C/com.example.vendor.other/blob" "top-level item ${APP_ROOT}/zz/yy/C/com.example.vendor.other: owning app is running" "folder under a running app's vendor prefix" "tmp-cleanup"
assert_moved "${app_output}" "${APP_ROOT}/zz/yy/C/com.unrelated.thing/blob" "file of an app that is not running"

print ""

# =============================================================================
# Processes started by this run do not count as someone else running
# =============================================================================
print "[TEST] own_descendants_ignored"

# ps shows argv[0] as the executable path, so this reads as a running brew
(exec -a "${TEST_TMPDIR}/bin/brew" /bin/sleep 30) &
own_brew_pid=$!
sleep 0.3
ps -eo comm= | grep -q "^${TEST_TMPDIR}/bin/brew$"
assert_eq "$?" "0" "the fixture brew process is visible to ps"
own_execs=$(_MAC_OPS_FC_RUNNING_EXECS=""; _mac_ops_fc_load_running_execs; print -r -- "${_MAC_OPS_FC_RUNNING_EXECS}")
assert_output_not_contains "${own_execs}" "${TEST_TMPDIR}/bin/brew" "a brew started by this run is left out of the process list"
assert_output_contains "${own_execs}" "/sbin/launchd" "other processes stay in the list"
kill "${own_brew_pid}" 2>/dev/null
wait "${own_brew_pid}" 2>/dev/null

print ""

# =============================================================================
# /tmp: the path is given to find as is (a symlinked root is not followed,
# as in main); agent scratch directories stay; files, not folders, are moved
# =============================================================================
print "[TEST] tmp_protection"

TMP_ROOT="${MAC_OPS_TMP_DIR}"
mkdir -p "${TMP_ROOT}/claude-501/session/scratchpad" "${TMP_ROOT}/Users/someone/project/dist" \
    "${TMP_ROOT}/Library/parked" "${TMP_ROOT}/.hidden-old"
print "x" > "${TMP_ROOT}/claude-501/session/scratchpad/notes"
print "x" > "${TMP_ROOT}/Users/someone/project/dist/bundle.js"
print "x" > "${TMP_ROOT}/Library/parked/old-file"
print "x" > "${TMP_ROOT}/Library/parked/new-file"
print "x" > "${TMP_ROOT}/.hidden-old/file"
make_old "${TMP_ROOT}/claude-501"
make_old "${TMP_ROOT}/Users"
make_old "${TMP_ROOT}/.hidden-old"
touch -t "${OLD_STAMP}" "${TMP_ROOT}/Library" "${TMP_ROOT}/Library/parked/old-file"

ln -s "${TMP_ROOT}" "${TEST_TMPDIR}/tmp-link"

_MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder"
tmp_output=$(_mac_ops_tmp_clean_path "${TEST_TMPDIR}/tmp-link" 3 "tmp-expired" 2>&1)
assert_output_not_contains "${tmp_output}" "Will move to trash" "a symlinked scan root is not followed (main's find does not follow /tmp)"

tmp_output=$(_mac_ops_tmp_clean_path "${TMP_ROOT}" 3 "tmp-expired" 2>&1)
assert_survives "${tmp_output}" "${TMP_ROOT}/claude-501/session/scratchpad/notes" "agent scratch directory" "file in a claude-* scratch directory" "tmp-cleanup"
assert_survives "${tmp_output}" "${TMP_ROOT}/Library/parked/old-file" "top-level item" "old file next to a fresh file" "tmp-cleanup"
assert_moved "${tmp_output}" "${TMP_ROOT}/Users/someone/project/dist/bundle.js" "old parked file"
assert_moved "${tmp_output}" "${TMP_ROOT}/.hidden-old/file" "old file in a hidden directory"
assert_output_not_contains "${tmp_output}" "Will move to trash: ${TMP_ROOT}/Users " "a parked directory is not moved as a whole"

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
# Developer caches: dry-run lists what a real run would move, item by item
# =============================================================================
print "[TEST] dev_dry_run_matches_real_run"

DERIVED="${HOME}/Library/Developer/Xcode/DerivedData"
SIMCACHE="${HOME}/Library/Developer/CoreSimulator/Caches"
mkdir -p "${DERIVED}/Idle-abc" "${DERIVED}/Held-def" "${SIMCACHE}/dyld" "${SIMCACHE}/held"
print "x" > "${DERIVED}/Idle-abc/data"
# DerivedData now has an age limit: the idle fixture must be older than the threshold
make_old "${DERIVED}/Idle-abc"
print "x" > "${DERIVED}/Held-def/data"
print "x" > "${SIMCACHE}/dyld/data"
print "x" > "${SIMCACHE}/held/data"

seed_running "${IDLE_PROCESSES}"
_MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder
n${DERIVED}/Held-def/data
n${SIMCACHE}/held/data"
dev_output=$(_mac_ops_dev_xcode 2>&1)
assert_moved "${dev_output}" "${DERIVED}/Idle-abc" "idle DerivedData item"
assert_survives "${dev_output}" "${DERIVED}/Held-def" "open by a running process" "DerivedData item open in a process" "dev-cleanup"
assert_moved "${dev_output}" "${SIMCACHE}/dyld" "idle simulator cache item"
assert_survives "${dev_output}" "${SIMCACHE}/held" "open by a running process" "simulator cache item open in a process" "dev-cleanup"
assert_output_not_contains "${dev_output}" "Will clean: ${DERIVED} " "dry-run does not announce the whole DerivedData folder"

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
