#!/bin/zsh
# =============================================================================
# mac-ops: self-protection tests for the path-safety check
# Every fixture lives under mktemp -d; nothing outside it is touched.
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
export MAC_OPS_HOME="${HOME}/.mac-ops"
export MAC_OPS_TRASH_DIR="${MAC_OPS_HOME}/.trash"
export MAC_OPS_META_DIR="${MAC_OPS_HOME}/.metadata"
export MAC_OPS_LOG_DIR="${MAC_OPS_HOME}/.logs"
export MAC_OPS_LOCK_FILE="${MAC_OPS_HOME}/mac-ops.lock"
export MAC_OPS_CONFIG_FILE="${MAC_OPS_HOME}/config.plist"
mkdir -p "${HOME}/Library/Caches/com.example.app"

for lib_file in core/config core/logger core/safety; do
    source "${MAC_OPS_ROOT}/lib/${lib_file}.zsh"
done

print "=== mac-ops self-protection tests ==="
print ""

# === Self-protection (item 11) ===
assert_refused() {
    mac_ops_is_path_safe "$1" >/dev/null 2>&1
    assert_eq "$?" "1" "$2"
}

test_selfprotect_mac_ops_home() {
    print "[TEST] selfprotect_mac_ops_home"
    assert_refused "${MAC_OPS_HOME}" "mac-ops home refused"
    assert_refused "${MAC_OPS_HOME}/" "mac-ops home with trailing slash refused"
    assert_refused "${MAC_OPS_TRASH_DIR}/Users/x/file" "child of mac-ops trash refused"
    assert_refused "${MAC_OPS_HOME}/sub/../.logs/a.log" "dotdot inside mac-ops home refused"
    assert_refused "${HOME}/Library/../.mac-ops/.trash" "dotdot into mac-ops home refused"
}

test_selfprotect_companion_dirs() {
    print "[TEST] selfprotect_companion_dirs"
    local d
    for d in "${HOME}/.mac-optimize" "${HOME}/.mole/trash"; do
        assert_refused "${d}" "${d#"${HOME}/"} refused"
        assert_refused "${d}/child/file.txt" "child of ${d#"${HOME}/"} refused"
    done
}

test_selfprotect_tmp_parking_dirs() {
    print "[TEST] selfprotect_tmp_parking_dirs"
    local n base
    for n in Users Library Applications usr opt private; do
        for base in /tmp /private/tmp; do
            assert_refused "${base}/${n}" "${base}/${n} refused"
            assert_refused "${base}/${n}/" "${base}/${n}/ (trailing slash) refused"
            assert_refused "${base}/${n}/child/x" "child of ${base}/${n} refused"
        done
    done
    assert_refused "/tmp/foo/../Users/x" "dotdot into /tmp/Users refused"
    assert_refused "/tmp//Users//x" "double slashes in /tmp/Users path refused"
}

test_selfprotect_symlink() {
    print "[TEST] selfprotect_symlink"
    mkdir -p "${MAC_OPS_HOME}"
    ln -s "${MAC_OPS_HOME}" "${TEST_TMPDIR}/link-to-home"
    assert_refused "${TEST_TMPDIR}/link-to-home/.trash" "symlink into mac-ops home refused"
}

test_selfprotect_allows_ordinary() {
    print "[TEST] selfprotect_allows_ordinary"
    mac_ops_is_path_safe "${HOME}/Library/Caches/com.example.app" >/dev/null 2>&1
    assert_eq "$?" "0" "ordinary cache path allowed"
    mac_ops_is_path_safe "/tmp/Usersfoo/x" >/dev/null 2>&1
    assert_eq "$?" "0" "/tmp/Usersfoo (prefix lookalike) allowed"
    mac_ops_is_path_safe "${HOME}/.mac-ops-other/x" >/dev/null 2>&1
    assert_eq "$?" "0" ".mac-ops-other (prefix lookalike) allowed"
}

test_selfprotect_mac_ops_home
test_selfprotect_companion_dirs
test_selfprotect_tmp_parking_dirs
test_selfprotect_symlink
test_selfprotect_allows_ordinary

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
