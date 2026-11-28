#!/bin/zsh
# =============================================================================
# mac-ops: orphan-killer unit tests
#
# Safety: this file never signals a process it did not start itself.
# The module's only signalling function is replaced by a recording stub, and
# the predicates are exercised with synthetic process tables.
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

# --- Project root ---
MAC_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_FILE="${MAC_OPS_ROOT}/lib/modules/orphan-killer.zsh"

# --- Test environment ---
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
export MAC_OPS_SCHEDULED=false
unset MAC_OPS_ORPHAN_ACTION
unset MAC_OPS_ORPHAN_MIN_RUNNING_HOURS

# --- Processes started by this test (always cleaned up) ---
typeset -a TEST_CHILD_PIDS
TEST_CHILD_PIDS=()

cleanup() {
    local child
    for child in "${TEST_CHILD_PIDS[@]}"; do
        kill -TERM "${child}" 2>/dev/null
        wait "${child}" 2>/dev/null
    done
    TEST_CHILD_PIDS=()
    [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]] && rm -rf "${TEST_TMPDIR}"
}
trap cleanup EXIT

print "=== mac-ops orphan-killer tests ==="
print ""

source "${MAC_OPS_ROOT}/lib/core/config.zsh"
source "${MAC_OPS_ROOT}/lib/core/logger.zsh"
source "${MAC_OPS_ROOT}/lib/core/safety.zsh"
source "${MAC_OPS_ROOT}/lib/core/ignore.zsh"
source "${MODULE_FILE}"

mac_ops_init_dirs
MAC_OPS_KILLED_COUNT=0

# --- Replace the module's only signalling function with a recording stub ---
typeset -a SIGNAL_CALLS
SIGNAL_CALLS=()
_mac_ops_orphan_signal_term() {
    SIGNAL_CALLS+=("${1}")
    return 0
}

# --- Process titles come from this map, never from the live table, so a real
# PID that happens to equal a synthetic PID cannot change a result ---
typeset -gA TEST_TITLES
TEST_TITLES=()
_mac_ops_orphan_title() {
    print -r -- "${TEST_TITLES[${1}]:-${_MAC_OPS_ORPHAN_EXE[${1}]}}"
}

# --- Synthetic process table: pid ppid uid tty etime rss comm ---
OTHER_UID=$((UID + 1))
SYNTH_TABLE="
1 0 0 ?? 9-00:00:00 1000 /sbin/launchd
400 1 ${UID} ?? 2-00:00:00 2048 /opt/tools/bin/supervisor
500 400 ${UID} ?? 01:00 1024 /opt/tools/bin/runner
600 500 ${UID} ?? 00:30 512 /opt/tools/bin/worker
601 600 ${UID} ?? 00:10 512 /opt/tools/bin/leaf
700 1 ${UID} ?? 3-01:02:03 4096 /opt/homebrew/bin/node
705 1 ${UID} ?? 05:00:00 4096 /opt/homebrew/bin/node
710 1 ${UID} ttys003 2-00:00:00 100 /opt/tools/bin/attached
720 1 ${UID} ?? 2-00:00:00 100 /opt/tools/bin/wrapper
721 720 ${UID} ttys001 2-00:00:00 100 /opt/tools/bin/attached-child
730 1 ${UID} ?? 2-00:00:00 100 /opt/homebrew/bin/npm
731 730 ${UID} ?? 2-00:00:00 100 /opt/homebrew/bin/python3
732 731 ${UID} ?? 2-00:00:00 100 -zsh
740 1 ${UID} ?? 2-00:00:00 100 /opt/homebrew/bin/tmux
745 1 ${UID} ?? 2-00:00:00 100 /Users/me/.local/bin/Claude
750 1 ${UID} ?? 2-00:00:00 100 /opt/AhnLab/ASTx/astxd
760 1 ${UID} ?? 2-00:00:00 100 /opt/tools/bin/managed
770 1 ${UID} ?? 2-00:00:00 100 /Users/me/Tools/Thing.app/Contents/MacOS/Thing Helper
780 1 ${OTHER_UID} ?? 2-00:00:00 100 /opt/tools/bin/foreign
790 1 ${UID} ?? 2-00:00:00 100 /opt/My Tools/popoutZoom helper
795 1 ${UID} ?? 2-00:00:00 100 /opt/tools/bin/Finder
"
SYNTH_LAUNCHD="PID	Status	Label
760	0	com.example.managed
-	0	com.example.idle"

load_synthetic() {
    _mac_ops_orphan_load_snapshot "${SYNTH_TABLE}" "${1:-500}"
    _mac_ops_orphan_load_launchd "${SYNTH_LAUNCHD}"
}

# =============================================================================
# test_default_action_is_report
# =============================================================================
print "[TEST] test_default_action_is_report"

assert_eq "${MAC_OPS_ORPHAN_ACTION}" "report" "MAC_OPS_ORPHAN_ACTION defaults to report"
assert_eq "$(_mac_ops_orphan_action)" "report" "resolved action is report by default"

for _value in "" "kill" "TERM" "true" "yes" "1" "term "; do
    assert_eq "$(MAC_OPS_ORPHAN_ACTION="${_value}" _mac_ops_orphan_action)" "report" "action '${_value}' resolves to report"
done
assert_eq "$(MAC_OPS_ORPHAN_ACTION="term" _mac_ops_orphan_action)" "term" "only the exact value 'term' enables SIGTERM"

# Report mode refuses to signal even a live, matching process of our own
sleep 300 &
REPORT_PID=$!
TEST_CHILD_PIDS+=("${REPORT_PID}")
REPORT_LSTART=$(_mac_ops_orphan_lstart "${REPORT_PID}")
REPORT_EXE=$(_mac_ops_orphan_exe "${REPORT_PID}")

MAC_OPS_DRY_RUN=false
_mac_ops_orphan_terminate "${REPORT_PID}" "${REPORT_LSTART}" "${REPORT_EXE}" >/dev/null 2>&1
assert_exit_code "$?" "2" "report mode refuses to signal (return 2)"
MAC_OPS_DRY_RUN=true
assert_eq "${#SIGNAL_CALLS[@]}" "0" "report mode sent no signal"

# Full module run (dry-run, live table, signalling stubbed)
REPORT_OUTPUT=$(mac_ops_orphan_killer 2>&1)
assert_exit_code "$?" "0" "module run in dry-run completes without error"
assert_output_contains "${REPORT_OUTPUT}" "Orphan process action: report" "module run logs the report action"
assert_output_contains "${REPORT_OUTPUT}" "0 signalled (report only)" "module run reports without signalling"
assert_output_not_contains "${REPORT_OUTPUT}" "PID ${REPORT_PID} " "own sleep child is not reported as a candidate"
assert_eq "${#SIGNAL_CALLS[@]}" "0" "module run sent no signal"

# The module may only ever send TERM
KILL_LINES=$(grep -c -E '(^|[^_a-zA-Z])kill[[:space:]]+-' "${MODULE_FILE}")
assert_eq "${KILL_LINES}" "1" "module contains exactly one kill invocation"
assert_output_contains "$(grep -E '(^|[^_a-zA-Z])kill[[:space:]]+-' "${MODULE_FILE}")" "kill -TERM" "the only kill invocation sends TERM"

print ""

# =============================================================================
# test_tree_walk_exclusion
# =============================================================================
print "[TEST] test_tree_walk_exclusion"

# Live table: a sleep child of this test shell is never a candidate
sleep 300 &
TREE_PID=$!
TEST_CHILD_PIDS+=("${TREE_PID}")

_mac_ops_orphan_load_snapshot
assert_exit_code "$?" "0" "live process table snapshot loads"
_mac_ops_orphan_load_launchd

assert_eq "${_MAC_OPS_ORPHAN_PPID[${TREE_PID}]}" "$$" "snapshot records the sleep child under this shell"
_mac_ops_orphan_in_own_tree "${TREE_PID}"
assert_exit_code "$?" "0" "sleep child is in the own process tree"
_mac_ops_orphan_in_own_tree "$$"
assert_exit_code "$?" "0" "current shell is in the own process tree"
_mac_ops_orphan_in_own_tree "${PPID}"
assert_exit_code "$?" "0" "parent of the current shell is in the own process tree"
_mac_ops_orphan_in_own_tree "1"
assert_exit_code "$?" "1" "PID 1 is not treated as part of the own process tree"
_mac_ops_orphan_classify "${TREE_PID}"
assert_exit_code "$?" "1" "sleep child is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "own process tree" "sleep child is rejected by the own-tree check"

# Synthetic table, self = 500: 400 (ancestor, parent-1, old), 600/601 (descendants)
load_synthetic 500
for _own in 400 500 600 601; do
    _mac_ops_orphan_in_own_tree "${_own}"
    assert_exit_code "$?" "0" "synthetic PID ${_own} is in the own process tree"
    _mac_ops_orphan_classify "${_own}"
    assert_exit_code "$?" "1" "synthetic PID ${_own} is not a candidate"
done
_mac_ops_orphan_classify 400
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "own process tree" "parent-1 ancestor is rejected by the own-tree check"
_mac_ops_orphan_in_own_tree 700
assert_exit_code "$?" "1" "unrelated PID 700 is not in the own process tree"

# Same table seen from an unrelated shell: 400 is no longer rejected by the
# own-tree check (it is still rejected, because it has a child process)
load_synthetic 99999
_mac_ops_orphan_classify 400
assert_exit_code "$?" "1" "parent-1 process with children is not a candidate even when it is not our ancestor"
assert_output_not_contains "${_MAC_OPS_ORPHAN_REASON}" "own process tree" "unrelated shell: 400 is not rejected by the own-tree check"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "has child process PID 500" "unrelated shell: 400 is rejected because it has a child"

assert_eq "$(_mac_ops_orphan_ancestors 601 | tr '\n' ' ')" "600 500 400 " "ancestors are walked up to PID 1"
assert_eq "$(_mac_ops_orphan_descendants 400 | tr '\n' ' ')" "500 600 601 " "descendants are walked breadth first"

print ""

# =============================================================================
# test_candidate_rule
# =============================================================================
print "[TEST] test_candidate_rule"

load_synthetic 500

_mac_ops_orphan_classify 700
assert_exit_code "$?" "0" "old parent-1 process with no tty/launchd/app/session is a candidate"
for _check in "parent is PID 1" "not launchd-managed" "no controlling tty" "not inside a .app bundle" "no terminal/shell/tmux/agent relative" "not security software" "not in own process tree" "running 73h >= 24h"; do
    assert_output_contains "${_MAC_OPS_ORPHAN_CHECKS}" "${_check}" "candidate lists passed check: ${_check}"
done

_mac_ops_orphan_classify 705
assert_exit_code "$?" "1" "parent-1 process below the uptime threshold is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "below the 24h threshold" "rejected by the uptime threshold"

_mac_ops_orphan_classify 601
assert_exit_code "$?" "1" "process whose parent is not PID 1 is not a candidate"

_mac_ops_orphan_classify 760
assert_exit_code "$?" "1" "launchd-managed PID is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "managed by launchd" "rejected because its PID is in launchctl list"

_mac_ops_orphan_classify 770
assert_exit_code "$?" "1" "executable inside a .app bundle is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" ".app bundle" "rejected by the .app check"

_mac_ops_orphan_classify 780
assert_exit_code "$?" "1" "process of another user is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "another user" "rejected by the owner check"

_mac_ops_orphan_classify 730
assert_exit_code "$?" "1" "parent-1 process with a shell descendant is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "descendant PID 732" "rejected because a descendant is a shell"

_mac_ops_orphan_classify 740
assert_exit_code "$?" "1" "tmux server is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "session" "tmux is rejected as a session"

_mac_ops_orphan_classify 745
assert_exit_code "$?" "1" "coding-agent executable is not a candidate"

_mac_ops_orphan_classify 4242424
assert_exit_code "$?" "1" "PID missing from the snapshot is not a candidate"

print ""

# =============================================================================
# test_tty_exclusion
# =============================================================================
print "[TEST] test_tty_exclusion"

load_synthetic 500

_mac_ops_orphan_classify 710
assert_exit_code "$?" "1" "parent-1 process with a controlling tty is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "controlling tty ttys003" "rejected by the tty check"

_mac_ops_orphan_classify 720
assert_exit_code "$?" "1" "parent-1 process with a tty-attached descendant is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "descendant PID 721 has controlling tty" "rejected by the descendant tty check"

# Same rows without a tty: 710 qualifies, so the tty is what excluded it;
# 720 is still rejected, now only because it has a child process
_mac_ops_orphan_load_snapshot "${SYNTH_TABLE//ttys00[0-9]/??}" 500
_mac_ops_orphan_classify 710
assert_exit_code "$?" "0" "same process without a tty is a candidate"
_mac_ops_orphan_classify 720
assert_exit_code "$?" "1" "same process without a tty-attached descendant is still not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "has child process PID 721" "720 without a tty child is rejected because it has a child"

_mac_ops_orphan_has_tty "ttys001"
assert_exit_code "$?" "0" "ttys001 is a controlling tty"
for _tty in "??" "?" "-" ""; do
    _mac_ops_orphan_has_tty "${_tty}"
    assert_exit_code "$?" "1" "'${_tty}' is not a controlling tty"
done

print ""

# =============================================================================
# test_executable_vs_arguments
# =============================================================================
print "[TEST] test_executable_vs_arguments"

# A real process whose ARGUMENTS contain protected words but whose executable
# does not: it must be judged by the executable.
perl -e 'sleep 300' fortinet-AhnLab Finder tmux popoutZoom &
ARGS_PID=$!
TEST_CHILD_PIDS+=("${ARGS_PID}")
sleep 1

ARGS_ARGS=$(ps -o args= -p "${ARGS_PID}" 2>/dev/null)
_mac_ops_orphan_load_snapshot
ARGS_EXE="${_MAC_OPS_ORPHAN_EXE[${ARGS_PID}]}"

assert_output_contains "${ARGS_ARGS}" "fortinet-AhnLab Finder tmux popoutZoom" "arguments contain the protected words"
assert_output_contains "${ARGS_EXE}" "perl" "snapshot records the executable"
assert_output_not_contains "${ARGS_EXE}" "fortinet" "snapshot does not record the arguments"
assert_eq "${ARGS_EXE}" "$(_mac_ops_orphan_exe "${ARGS_PID}")" "snapshot executable equals ps -o comm="

_mac_ops_orphan_is_security_software "${ARGS_EXE}"
assert_exit_code "$?" "1" "security keyword in arguments does not match"
_mac_ops_orphan_is_session_exe "${ARGS_EXE}"
assert_exit_code "$?" "1" "session name in arguments does not match"
mac_ops_is_process_protected "${ARGS_EXE##*/}" >/dev/null 2>&1
assert_exit_code "$?" "0" "protected process name in arguments does not match"

# Executable names decide, in both directions
load_synthetic 500
assert_eq "${_MAC_OPS_ORPHAN_EXE[790]}" "/opt/My Tools/popoutZoom helper" "executable path with spaces is kept whole"
_mac_ops_orphan_classify 790
assert_exit_code "$?" "0" "executable merely containing 'Zoom' is judged on its own name"

_mac_ops_orphan_classify 795
assert_exit_code "$?" "1" "executable named like a protected process is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "protected process" "rejected by the protected-process list"

_MAC_OPS_IGNORE_PROCESSES=("popoutZoom*")
_mac_ops_orphan_classify 790
assert_exit_code "$?" "1" "user ignore rule matching the executable name applies"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "user ignore rule" "rejected by the user ignore rule"
_mac_ops_orphan_classify 700
assert_exit_code "$?" "0" "user ignore rule does not match another executable"
_MAC_OPS_IGNORE_PROCESSES=()

_mac_ops_orphan_is_session_exe "/opt/homebrew/bin/tmux"
assert_exit_code "$?" "0" "tmux executable is a session"
_mac_ops_orphan_is_session_exe "-zsh"
assert_exit_code "$?" "0" "login shell is a session"
_mac_ops_orphan_is_session_exe "/opt/tools/bin/tmux-status-helper"
assert_exit_code "$?" "1" "session names match the whole executable name, not a substring"

print ""

# =============================================================================
# test_security_keywords
# =============================================================================
print "[TEST] test_security_keywords"

EXPECTED_KEYWORDS=(
    fortinet forticlient ahnlab astx jiran jkok pnpsecure pcassist
    wizvera delfino veraport iniline crossex initech inisafe nprotect
    raon touchen
)

assert_eq "${#_MAC_OPS_ORPHAN_SECURITY_KEYWORDS[@]}" "${#EXPECTED_KEYWORDS[@]}" "security keyword list has ${#EXPECTED_KEYWORDS[@]} entries"

for _keyword in "${EXPECTED_KEYWORDS[@]}"; do
    _mac_ops_orphan_is_security_software "/Library/Vendor/${(U)_keyword}/bin/agentd"
    assert_exit_code "$?" "0" "security keyword matches case-insensitively: ${_keyword}"
done

for _exe in "/opt/homebrew/bin/node" "/usr/local/bin/python3" "/opt/tools/bin/supervisor" ""; do
    _mac_ops_orphan_is_security_software "${_exe}"
    assert_exit_code "$?" "1" "not security software: '${_exe}'"
done

load_synthetic 500
_mac_ops_orphan_classify 750
assert_exit_code "$?" "1" "security software is not a candidate"
assert_eq "${_MAC_OPS_ORPHAN_REASON}" "security software" "rejected by the security software check"

print ""

# =============================================================================
# test_user_daemons
# Long-running tools a user starts on purpose look exactly like orphans
# (parent 1, no tty, days of uptime). They must never be candidates.
# =============================================================================
print "[TEST] test_user_daemons"

# Control row: the same shape with an unknown tool name is a candidate, so the
# daemon name is what rejects each row below
_mac_ops_orphan_load_snapshot "
1 0 0 ?? 9-00:00:00 1000 /sbin/launchd
900 1 ${UID} ?? 3-00:00:00 100 /opt/homebrew/bin/some-tool
" 99999
# Header-only list: no launchd-managed PIDs (an empty argument reads the live list)
_mac_ops_orphan_load_launchd "PID	Status	Label"
_mac_ops_orphan_classify 900
assert_exit_code "$?" "0" "control: unknown parent-1 tool running 3 days is a candidate"

for _daemon in gpg-agent ssh-agent ollama limactl colima qemu-system-aarch64 qemu-system-x86_64 \
    pm2 emacs tmux screen mosh-server syncthing rclone cloudflared ngrok tailscaled \
    postgres mysqld mariadbd redis-server mongod nginx httpd caddy dockerd containerd \
    podman jupyter jupyter-lab jupyter-notebook code-server GPG-Agent; do
    _mac_ops_orphan_load_snapshot "
1 0 0 ?? 9-00:00:00 1000 /sbin/launchd
900 1 ${UID} ?? 3-00:00:00 100 /opt/homebrew/bin/${_daemon}
" 99999
    _mac_ops_orphan_classify 900
    assert_exit_code "$?" "1" "user daemon is not a candidate: ${_daemon}"
    # tmux/screen/mosh-server/ssh-agent are also sessions; that check runs first
    if ! _mac_ops_orphan_is_session_exe "/opt/homebrew/bin/${_daemon}"; then
        assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "user daemon" "user daemon rejected by the daemon list: ${_daemon}"
    fi
    _mac_ops_orphan_is_user_daemon "/opt/homebrew/bin/${_daemon}" "/opt/homebrew/bin/${_daemon}"
    assert_exit_code "$?" "0" "daemon list matches the base name: ${_daemon}"
done

# Names are compared as whole base names, not substrings
for _exe in /opt/tools/bin/nginx-log-tail /opt/tools/bin/my-ollama-notes /opt/tools/bin/postgresql-backup-report; do
    _mac_ops_orphan_is_user_daemon "${_exe}" "${_exe}"
    assert_exit_code "$?" "1" "not a user daemon (substring only): ${_exe}"
done

# limactl with a qemu child, rejected no matter which check fires first
_mac_ops_orphan_load_snapshot "
1 0 0 ?? 9-00:00:00 1000 /sbin/launchd
910 1 ${UID} ?? 3-00:00:00 100 /opt/homebrew/bin/limactl
911 910 ${UID} ?? 3-00:00:00 100 /opt/homebrew/bin/qemu-system-aarch64
" 99999
_mac_ops_orphan_classify 910
assert_exit_code "$?" "1" "limactl with a qemu child is not a candidate"

# node: a pm2 God daemon (title starts with PM2) is protected, a bare node is not
_mac_ops_orphan_load_snapshot "
1 0 0 ?? 9-00:00:00 1000 /sbin/launchd
920 1 ${UID} ?? 3-00:00:00 100 /opt/homebrew/bin/node
921 1 ${UID} ?? 3-00:00:00 100 /opt/homebrew/bin/node
922 1 ${UID} ?? 3-00:00:00 100 PM2 v5.4.2: God Daemon (/Users/me/.pm2)
" 99999
TEST_TITLES=(920 "PM2 v5.4.2: God Daemon (/Users/me/.pm2)" 921 "/opt/homebrew/bin/node /Users/me/app/server.js")
_mac_ops_orphan_classify 920
assert_exit_code "$?" "1" "node whose process title starts with PM2 is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "pm2" "pm2 God daemon is rejected as a pm2 daemon"
_mac_ops_orphan_classify 921
assert_exit_code "$?" "0" "bare node without a PM2 title is still judged by the other rules"
_mac_ops_orphan_classify 922
assert_exit_code "$?" "1" "executable reported as the PM2 title is not a candidate"
TEST_TITLES=()

print ""

# =============================================================================
# test_child_process_rule
# =============================================================================
print "[TEST] test_child_process_rule"

_mac_ops_orphan_load_snapshot "
1 0 0 ?? 9-00:00:00 1000 /sbin/launchd
930 1 ${UID} ?? 3-00:00:00 100 /opt/tools/bin/parentd
931 930 ${UID} ?? 3-00:00:00 100 /opt/tools/bin/kid
940 1 ${UID} ?? 3-00:00:00 100 /opt/tools/bin/parentd
" 99999
_mac_ops_orphan_classify 930
assert_exit_code "$?" "1" "parent-1 process with a child is not a candidate"
assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "has child process PID 931" "rejected because something depends on it"
_mac_ops_orphan_classify 940
assert_exit_code "$?" "0" "same executable without a child is a candidate"

print ""

# =============================================================================
# test_min_hours_validation
# =============================================================================
print "[TEST] test_min_hours_validation"

_mac_ops_orphan_load_snapshot "
1 0 0 ?? 9-00:00:00 1000 /sbin/launchd
950 1 ${UID} ?? 01:00:00 100 /opt/tools/bin/young
951 1 ${UID} ?? 2-00:00:00 100 /opt/tools/bin/older
" 99999

for _hours in abc 0 -5 24h 00 " " "1.5" "99999999999999999999"; do
    assert_eq "$(MAC_OPS_ORPHAN_MIN_RUNNING_HOURS="${_hours}" _mac_ops_orphan_min_hours 2>/dev/null)" "24" "invalid hours '${_hours}' falls back to 24"
    MAC_OPS_ORPHAN_MIN_RUNNING_HOURS="${_hours}" _mac_ops_orphan_min_hours >/dev/null 2>&1
    assert_exit_code "$?" "1" "invalid hours '${_hours}' is reported as invalid"
    _HOURS_ERR=$(MAC_OPS_ORPHAN_MIN_RUNNING_HOURS="${_hours}" _mac_ops_orphan_classify 950 2>&1)
    assert_output_not_contains "${_HOURS_ERR}" "bad math" "invalid hours '${_hours}' causes no math error"
    MAC_OPS_ORPHAN_MIN_RUNNING_HOURS="${_hours}" _mac_ops_orphan_classify 950 2>/dev/null
    assert_exit_code "$?" "1" "invalid hours '${_hours}' keeps the uptime filter on (1h process rejected)"
    assert_output_contains "${_MAC_OPS_ORPHAN_REASON}" "below the 24h threshold" "invalid hours '${_hours}' uses the 24h threshold"
done

for _hours in 1 24 48 08; do
    assert_eq "$(MAC_OPS_ORPHAN_MIN_RUNNING_HOURS="${_hours}" _mac_ops_orphan_min_hours)" "$((10#${_hours}))" "valid hours '${_hours}' is used"
done
MAC_OPS_ORPHAN_MIN_RUNNING_HOURS=1 _mac_ops_orphan_classify 950
assert_exit_code "$?" "0" "hours 1: a 1h-old process is a candidate"
MAC_OPS_ORPHAN_MIN_RUNNING_HOURS=48 _mac_ops_orphan_classify 951
assert_exit_code "$?" "0" "hours 48: a 48h-old process is a candidate"
MAC_OPS_ORPHAN_MIN_RUNNING_HOURS=49 _mac_ops_orphan_classify 951
assert_exit_code "$?" "1" "hours 49: a 48h-old process is not a candidate"

print ""

# =============================================================================
# test_stale_pid_recheck
# =============================================================================
print "[TEST] test_stale_pid_recheck"

sleep 300 &
STALE_PID=$!
TEST_CHILD_PIDS+=("${STALE_PID}")
sleep 1
STALE_LSTART=$(_mac_ops_orphan_lstart "${STALE_PID}")
STALE_EXE=$(_mac_ops_orphan_exe "${STALE_PID}")

assert_eq "$([[ -n "${STALE_LSTART}" ]] && print yes)" "yes" "start time of the test sleep is recorded"
assert_output_contains "${STALE_EXE}" "sleep" "executable of the test sleep is recorded"

_mac_ops_orphan_verify "${STALE_PID}" "${STALE_LSTART}" "${STALE_EXE}"
assert_exit_code "$?" "5" "same start time and executable pass the identity check, then the fresh row is reclassified (our own child: not a candidate)"
_mac_ops_orphan_verify "${STALE_PID}" "Thu Jan  1 00:00:00 1970" "${STALE_EXE}"
assert_exit_code "$?" "1" "different start time does not verify"
_mac_ops_orphan_verify "${STALE_PID}" "${STALE_LSTART}" "/opt/tools/bin/other"
assert_exit_code "$?" "1" "different executable does not verify"
_mac_ops_orphan_verify "${STALE_PID}" "" "${STALE_EXE}"
assert_exit_code "$?" "1" "missing recorded start time does not verify"

# Signalling is stubbed; these calls only reach the stub.
SIGNAL_CALLS=()
MAC_OPS_ORPHAN_ACTION=term

MAC_OPS_DRY_RUN=true
_mac_ops_orphan_terminate "${STALE_PID}" "${STALE_LSTART}" "${STALE_EXE}" >/dev/null 2>&1
assert_exit_code "$?" "3" "dry-run does not signal even in term mode (return 3)"
assert_eq "${#SIGNAL_CALLS[@]}" "0" "dry-run sent no signal"

MAC_OPS_DRY_RUN=false
_mac_ops_orphan_terminate "${STALE_PID}" "Thu Jan  1 00:00:00 1970" "${STALE_EXE}" >/dev/null 2>&1
assert_exit_code "$?" "1" "term mode refuses an entry whose start time changed"
_mac_ops_orphan_terminate "${STALE_PID}" "${STALE_LSTART}" "/opt/tools/bin/other" >/dev/null 2>&1
assert_exit_code "$?" "1" "term mode refuses an entry whose executable changed"
_mac_ops_orphan_terminate "1" "${STALE_LSTART}" "/sbin/launchd" >/dev/null 2>&1
assert_exit_code "$?" "1" "term mode refuses PID 1"
_mac_ops_orphan_terminate "$$" "${STALE_LSTART}" "${STALE_EXE}" >/dev/null 2>&1
assert_exit_code "$?" "1" "term mode refuses the current shell"
assert_eq "${#SIGNAL_CALLS[@]}" "0" "no signal for refused entries"

# The test sleep is really a child of this shell running /bin/sleep, so it
# would never classify as a candidate. To exercise the accept path, the fresh
# row and children used by the re-check are stubbed to describe it as a
# parent-1 tool; its start time is still read from the live table.
functions[_test_orig_exe]="${functions[_mac_ops_orphan_exe]}"
_mac_ops_orphan_exe() {
    if [[ "${1}" == "${STALE_PID}" ]]; then
        print -- "/opt/tools/bin/test-sleeper"
    else
        _test_orig_exe "${1}"
    fi
}
FRESH_PPID=1; FRESH_TTY="??"; FRESH_ETIME="2-00:00:00"; FRESH_KIDS=""; FRESH_GONE=false
_mac_ops_orphan_fresh_row() {
    [[ "${FRESH_GONE}" == "true" ]] && return 0
    print -r -- "${1} ${FRESH_PPID} ${UID} ${FRESH_TTY} ${FRESH_ETIME} 100 /opt/tools/bin/test-sleeper"
}
_mac_ops_orphan_fresh_kids() {
    [[ -n "${FRESH_KIDS}" ]] && print -r -- "${FRESH_KIDS}"
    return 0
}
load_synthetic 500
functions[_test_orig_load_launchd_pre]="${functions[_mac_ops_orphan_load_launchd]}"
_mac_ops_orphan_load_launchd() { return 0 }
_MAC_OPS_ORPHAN_LAUNCHD_PIDS=()
_MAC_OPS_ORPHAN_LAUNCHD_LABELS=""
STUB_EXE="/opt/tools/bin/test-sleeper"

_mac_ops_orphan_terminate "${STALE_PID}" "${STALE_LSTART}" "${STUB_EXE}" >/dev/null 2>&1
assert_exit_code "$?" "0" "term mode accepts a live entry that still matches and still qualifies"
assert_eq "${SIGNAL_CALLS[*]}" "${STALE_PID}" "exactly one TERM requested, for the verified PID"

# Same PID, same start time and executable, but the fresh row no longer
# qualifies: the signal must be refused
SIGNAL_CALLS=()
for _case in tty parent child young gone; do
    FRESH_PPID=1; FRESH_TTY="??"; FRESH_ETIME="2-00:00:00"; FRESH_KIDS=""; FRESH_GONE=false
    case "${_case}" in
        tty)    FRESH_TTY="ttys009" ;;
        parent) FRESH_PPID=700 ;;
        child)  FRESH_KIDS="4242" ;;
        young)  FRESH_ETIME="00:10" ;;
        gone)   FRESH_GONE=true ;;
    esac
    _RECHECK_OUT=$(_mac_ops_orphan_terminate "${STALE_PID}" "${STALE_LSTART}" "${STUB_EXE}" 2>&1)
    assert_exit_code "$?" "1" "re-check refuses a PID whose fresh row no longer qualifies (${_case})"
    assert_output_contains "${_RECHECK_OUT}" "no longer" "refusal after re-classification is logged (${_case})"
done
_mac_ops_orphan_terminate "${STALE_PID}" "${STALE_LSTART}" "${STUB_EXE}" >/dev/null 2>&1
assert_eq "${#SIGNAL_CALLS[@]}" "0" "no signal for entries that no longer qualify"

# The full classification runs again, so a rule that changed since the
# listing (here: a new ignore entry) also refuses the signal
FRESH_PPID=1; FRESH_TTY="??"; FRESH_ETIME="2-00:00:00"; FRESH_KIDS=""; FRESH_GONE=false
_MAC_OPS_IGNORE_PROCESSES=("test-sleeper")
_mac_ops_orphan_terminate "${STALE_PID}" "${STALE_LSTART}" "${STUB_EXE}" >/dev/null 2>&1
assert_exit_code "$?" "1" "re-check applies the ignore rules again"
_MAC_OPS_IGNORE_PROCESSES=()
assert_eq "${#SIGNAL_CALLS[@]}" "0" "no signal after an ignore rule was added"

functions[_mac_ops_orphan_exe]="${functions[_test_orig_exe]}"
functions[_mac_ops_orphan_load_launchd]="${functions[_test_orig_load_launchd_pre]}"

# Now end our own sleep and confirm the recorded entry is refused
SIGNAL_CALLS=()
kill -TERM "${STALE_PID}" 2>/dev/null
wait "${STALE_PID}" 2>/dev/null
TEST_CHILD_PIDS=("${(@)TEST_CHILD_PIDS:#${STALE_PID}}")

_mac_ops_orphan_verify "${STALE_PID}" "${STALE_LSTART}" "${STALE_EXE}"
assert_exit_code "$?" "1" "recorded entry no longer verifies after the process ended"
STALE_OUTPUT=$(_mac_ops_orphan_terminate "${STALE_PID}" "${STALE_LSTART}" "${STALE_EXE}" 2>&1)
assert_exit_code "$?" "1" "module refuses to signal the stale recorded entry"
assert_output_contains "${STALE_OUTPUT}" "refused" "refusal of the stale entry is logged"
_mac_ops_orphan_terminate "${STALE_PID}" "${STALE_LSTART}" "${STALE_EXE}" >/dev/null 2>&1
assert_eq "${#SIGNAL_CALLS[@]}" "0" "no signal for the stale entry"

MAC_OPS_DRY_RUN=true
MAC_OPS_ORPHAN_ACTION=report

print ""

# =============================================================================
# test_report_formatting
# =============================================================================
print "[TEST] test_report_formatting"

assert_eq "$(_mac_ops_orphan_format_uptime "3-01:02:03")" "3d 1h" "uptime is formatted as days and hours"
assert_eq "$(_mac_ops_orphan_format_rss "4608")" "4.5 MB" "memory is formatted in MB"
assert_eq "$(_mac_ops_parse_etime_hours "3-01:02:30")" "73" "etime with days parses to hours"
assert_eq "$(_mac_ops_parse_etime_hours "02:30")" "0" "etime without hours parses to 0"

print ""

# =============================================================================
# test_module_run_with_candidates
# Runs the main function over the synthetic table (always in dry-run, with
# signalling stubbed) so the report line and the SIGTERM phase are exercised.
# =============================================================================
print "[TEST] test_module_run_with_candidates"

functions[_test_orig_load_snapshot]="${functions[_mac_ops_orphan_load_snapshot]}"
functions[_test_orig_load_launchd]="${functions[_mac_ops_orphan_load_launchd]}"
_mac_ops_orphan_load_snapshot() { _test_orig_load_snapshot "${SYNTH_TABLE}" 500 }
_mac_ops_orphan_load_launchd() { _test_orig_load_launchd "${SYNTH_LAUNCHD}" }
_mac_ops_orphan_lstart() { print -- "Sat Nov  7 10:00:00 2026" }
_mac_ops_orphan_exe() { print -r -- "${_MAC_OPS_ORPHAN_EXE[${1}]}" }

SIGNAL_CALLS=()
MAC_OPS_KILLED_COUNT=0
MAC_OPS_DRY_RUN=true
MAC_OPS_ORPHAN_ACTION=report
RUN_OUTPUT=$(mac_ops_orphan_killer 2>&1)
RUN_LINE_700=$(print -r -- "${RUN_OUTPUT}" | grep "candidate: PID 700 ")

for _part in "uptime 3d 1h" "memory 4.0 MB" "executable /opt/homebrew/bin/node" "why: " "parent is PID 1" "not launchd-managed"; do
    assert_output_contains "${RUN_LINE_700}" "${_part}" "report line for PID 700 contains: ${_part}"
done
assert_output_contains "${RUN_OUTPUT}" "candidate: PID 790 | uptime 2d 0h | memory 0.0 MB | executable /opt/My Tools/popoutZoom helper |" "executable with spaces is reported whole"
assert_output_contains "${RUN_OUTPUT}" "2 candidates reported out of 14 parent-1 processes, 0 signalled (report only)" "report mode summary counts candidates"
for _rejected in 400 705 710 720 730 740 745 750 760 770 780 795; do
    assert_output_not_contains "${RUN_OUTPUT}" "candidate: PID ${_rejected} " "PID ${_rejected} is not reported"
done
assert_output_not_contains "${RUN_OUTPUT}" "SIGTERM to" "report mode does not announce any signal"

# An invalid hours value is warned about and replaced by 24 for the whole run
RUN_OUTPUT=$(MAC_OPS_ORPHAN_MIN_RUNNING_HOURS=abc mac_ops_orphan_killer 2>&1)
assert_output_contains "${RUN_OUTPUT}" "MAC_OPS_ORPHAN_MIN_RUNNING_HOURS='abc'" "invalid hours value is warned about"
assert_output_contains "${RUN_OUTPUT}" "threshold: running 24 hours or more" "invalid hours value runs with the 24h threshold"
assert_output_not_contains "${RUN_OUTPUT}" "candidate: PID 705 " "invalid hours value does not turn the uptime filter off"
assert_output_contains "${RUN_OUTPUT}" "2 candidates reported out of 14 parent-1 processes" "invalid hours value finds the same candidates as 24"

MAC_OPS_ORPHAN_ACTION=term
mac_ops_orphan_killer > "${TEST_TMPDIR}/term-run.log" 2>&1
RUN_OUTPUT=$(<"${TEST_TMPDIR}/term-run.log")
assert_output_contains "${RUN_OUTPUT}" "Orphan process action: term (SIGTERM only, never SIGKILL)" "term mode is logged"
assert_output_contains "${RUN_OUTPUT}" "[DRY_RUN] Will send SIGTERM to orphan process candidate PID 700 (/opt/homebrew/bin/node)" "term mode in dry-run announces PID 700"
assert_output_contains "${RUN_OUTPUT}" "[DRY_RUN] Will send SIGTERM to orphan process candidate PID 790 (/opt/My Tools/popoutZoom helper)" "candidate entry keeps the executable with spaces"
assert_output_contains "${RUN_OUTPUT}" "2 would be sent SIGTERM (dry-run, no signal sent)" "term mode dry-run summary says nothing was sent"
assert_eq "${MAC_OPS_KILLED_COUNT}" "2" "dry-run counts the candidates it would signal"
assert_eq "${#SIGNAL_CALLS[@]}" "0" "term mode in dry-run sent no signal"

MAC_OPS_ORPHAN_ACTION=report

print ""

# =============================================================================
# Cleanup
# =============================================================================
cleanup
trap - EXIT

# --- Summary ---
print "========================================="
print "Test results: ${TESTS_PASSED}/${TESTS_TOTAL} passed, ${TESTS_FAILED} failed"
print "========================================="

if [[ ${TESTS_FAILED} -gt 0 ]]; then
    exit 1
fi
exit 0
