#!/bin/zsh
# =============================================================================
# mac-ops: module safety tests (docker, zombie, dev, cache, orphan-app, brew)
# Every external command that could change the machine (docker, kill, brew,
# lsappinfo, ps, sleep) is replaced by a shell function that records its
# arguments to a file. Every block runs in a subshell that first checks the
# stubs are functions and exits 99 otherwise, so no real command is reached.
# All fixtures, including HOME and the mac-ops trash, live under mktemp -d.
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

# Pass when no line of the text matches the extended regex
assert_no_match() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    local hit
    hit=$(print -r -- "$1" | grep -E -- "$2" | head -1)
    if [[ -z "${hit}" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        print "  [PASS] $3"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        print "  [FAIL] $3 (matched: '${hit}')"
    fi
}

# --- Project root ---
MAC_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Test environment ---
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
    modules/tmp-cleanup modules/cache-cleanup modules/dev-cleanup modules/brew-cleanup \
    modules/docker-cleanup modules/zombie-killer modules/orphan-app-cleanup; do
    source "${MAC_OPS_ROOT}/lib/${lib_file}.zsh"
done
mac_ops_init_dirs

CALLS="${TEST_TMPDIR}/calls"
OLD_STAMP=202001010000
IDLE_PROCESSES="/sbin/launchd
/usr/libexec/logd"
make_old() { find "$1" -exec touch -t "${OLD_STAMP}" {} + }

# Exit 99 unless every named command is a shell function and the trash is a fixture
require_stubs() {
    local name
    [[ "${MAC_OPS_TRASH_DIR}" == "${TEST_TMPDIR}/"* && "${HOME}" == "${TEST_TMPDIR}/"* ]] || exit 99
    for name in "$@"; do
        [[ "$(whence -w "${name}")" == *": function" ]] || exit 99
    done
}

print "=== mac-ops module safety tests ==="
print ""

# =============================================================================
# Docker
# =============================================================================
docker_stub() {
    docker() {
        print -r -- "docker $*" >> "${CALLS}"
        case "${1}" in
            info)
                [[ -n "${DOCKER_INFO_SLEEP:-}" ]] && command sleep "${DOCKER_INFO_SLEEP}"
                return "${DOCKER_INFO_RC:-0}" ;;
            system) print "TYPE TOTAL ACTIVE SIZE RECLAIMABLE"; print "Build Cache 3 0 1GB 1GB" ;;
            *prune*|image|builder|container|volume) [[ "$*" == *prune* ]] && print "Total reclaimed space: 1MB" ;;
        esac
        return 0
    }
}

# Run the docker module with dry-run off. Usage: run_docker <action|__unset__>
run_docker() {
    : > "${CALLS}"
    (
        docker_stub
        require_stubs docker
        MAC_OPS_DRY_RUN=false
        if [[ "${1}" == "__unset__" ]]; then
            unset MAC_OPS_DOCKER_ACTION
        else
            MAC_OPS_DOCKER_ACTION="${1}"
        fi
        source "${MAC_OPS_ROOT}/lib/modules/docker-cleanup.zsh"
        mac_ops_docker_cleanup
    ) >/dev/null 2>&1
    cat "${CALLS}"
}

print "[TEST] docker_default_reports_only"
calls=$(run_docker "__unset__")
assert_output_contains "${calls}" "docker info" "daemon is probed"
assert_no_match "${calls}" "prune| rm( |$)|volume" "default action calls no prune, rm or volume subcommand"
calls=$(run_docker "Prune")
assert_no_match "${calls}" "prune| rm( |$)|volume" "any value other than 'prune' only reports"

print "[TEST] docker_prune_is_limited"
calls=$(run_docker "prune")
assert_eq "$(print -r -- "${calls}" | grep -c prune)" "2" "exactly two prune commands"
assert_output_contains "${calls}" "docker image prune -a --filter until=720h -f" "image prune with until filter"
assert_output_contains "${calls}" "docker builder prune --filter until=720h -f" "builder prune with until filter"
assert_no_match "${calls}" "container prune|volume prune|--volumes|system prune" "never container/volume/system prune or --volumes"
assert_eq "$(print -r -- "${calls}" | grep prune | grep -c -- '--filter until=720h')" "2" "every prune carries an until filter"
calls=$(MAC_OPS_DOCKER_PRUNE_UNTIL_HOURS=48 run_docker "prune")
assert_eq "$(print -r -- "${calls}" | grep prune | grep -c -- '--filter until=48h')" "2" "the age limit setting is used"

print "[TEST] docker_unreachable_daemon"
calls=$(DOCKER_INFO_RC=1 run_docker "prune")
assert_eq "${calls}" "docker info" "failed probe: no docker call beyond the probe"
start=${SECONDS}
calls=$(DOCKER_INFO_SLEEP=6 MAC_OPS_DOCKER_PROBE_TIMEOUT=1 run_docker "prune")
elapsed=$((SECONDS - start))
assert_eq "$((elapsed < 5))" "1" "hung daemon probe is bounded (${elapsed}s)"
assert_eq "${calls}" "docker info" "hung probe: no docker call beyond the probe"

# =============================================================================
# Zombie killer
# =============================================================================
# Two zombies with PIDs that cannot exist: one under an ordinary app, one under
# security software. The ps stub answers every form main and this branch use.
zombie_stubs() {
    ps() {
        local args="$*"
        case "${args}" in
            aux)
                print "USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND"
                print "u 9999991 0.0 0.0 0 0 ?? Z 1:00PM 0:00.00 (defunct)"
                print "u 9999992 0.0 0.0 0 0 ?? Z 1:00PM 0:00.00 (defunct)" ;;
            -axo*|-eo*)
                print "9999981 1 S 10:00:00 /Applications/Normal.app/Contents/MacOS/Normal"
                print "9999982 1 S 10:00:00 /Library/Application Support/AhnLab/ASTx/astxagent"
                print "9999991 9999981 Z 01:00 (defunct)"
                print "9999992 9999982 Z 01:00 (defunct)" ;;
            "-o ppid= -p 9999991") print "9999981" ;;
            "-o ppid= -p 9999992") print "9999982" ;;
            "-o comm= -p 9999981") print "/Applications/Normal.app/Contents/MacOS/Normal" ;;
            "-o comm= -p 9999982") print "/Library/Application Support/AhnLab/ASTx/astxagent" ;;
            "-o stat= -p "*) print "Z" ;;
            *) return 1 ;;
        esac
        return 0
    }
    kill() { print -r -- "kill $*" >> "${CALLS}"; return 0 }
    sleep() { return 0 }
}

# Usage: run_zombie <action|__unset__> <dry_run>
run_zombie() {
    : > "${CALLS}"
    (
        zombie_stubs
        require_stubs ps kill sleep
        MAC_OPS_DRY_RUN="${2}"
        if [[ "${1}" == "__unset__" ]]; then
            unset MAC_OPS_ZOMBIE_ACTION
        else
            MAC_OPS_ZOMBIE_ACTION="${1}"
        fi
        source "${MAC_OPS_ROOT}/lib/modules/zombie-killer.zsh"
        mac_ops_zombie_killer
    ) > "${TEST_TMPDIR}/zombie-out" 2>&1
    cat "${CALLS}"
}

TERM_KILL_RE='(SIG)?(TERM|KILL)|-(9|15)( |$)|-s +(TERM|KILL|9|15)'
print "[TEST] zombie_killer_never_terminates"
for action in __unset__ report sigchld SIGTERM; do
    calls=$(run_zombie "${action}" false)
    assert_no_match "${calls}" "${TERM_KILL_RE}" "action ${action}: no SIGTERM or SIGKILL"
    assert_no_match "${calls}" "9999982" "action ${action}: security software parent never signalled"
done

calls=$(run_zombie "__unset__" false)
assert_eq "${calls}" "" "default action sends no signal at all"
assert_output_contains "$(cat "${TEST_TMPDIR}/zombie-out")" "Zombie PID 9999991: parent PID 9999981 (/Applications/Normal.app/Contents/MacOS/Normal)" "zombie is reported with parent PID and executable"
calls=$(run_zombie "sigchld" false)
assert_eq "${calls}" "kill -CHLD 9999981" "opt-in sends only SIGCHLD to the ordinary parent"
calls=$(run_zombie "sigchld" true)
assert_eq "${calls}" "" "dry-run sends nothing"

# =============================================================================
# Dev cleanup: Archives are data; DerivedData and CocoaPods need an age limit
# =============================================================================
print "[TEST] xcode_archives_survive"
ARCH="${HOME}/Library/Developer/Xcode/Archives/2020-01-01/App 2020-01-01.xcarchive"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData"
mkdir -p "${ARCH}/dSYMs" "${DERIVED}/Old-abc" "${DERIVED}/Fresh-def"
print "x" > "${ARCH}/dSYMs/App.dSYM"
print "x" > "${DERIVED}/Old-abc/data"
print "x" > "${DERIVED}/Fresh-def/data"
make_old "${HOME}/Library/Developer/Xcode/Archives"
make_old "${DERIVED}/Old-abc"
dev_output=$(
    require_stubs
    MAC_OPS_DRY_RUN=false
    _MAC_OPS_FC_RUNNING_EXECS="${IDLE_PROCESSES}"
    _MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder"
    _mac_ops_dev_xcode 2>&1
)
assert_eq "$([[ -f "${ARCH}/dSYMs/App.dSYM" ]] && print yes || print no)" "yes" "old Xcode archive is not moved"
assert_output_contains "${dev_output}" "Xcode Archives: 1 archives" "archives are reported with count and size"
assert_eq "$([[ -d "${DERIVED}/Fresh-def" ]] && print yes || print no)" "yes" "DerivedData used within the age limit is not moved"
assert_eq "$([[ -d "${DERIVED}/Old-abc" ]] && print yes || print no)" "no" "old DerivedData is moved"

print "[TEST] cocoapods_age_limit"
PODS="${HOME}/Library/Caches/CocoaPods"
mkdir -p "${PODS}/Pods-old" "${PODS}/Pods-fresh"
print "x" > "${PODS}/Pods-old/a"
print "x" > "${PODS}/Pods-fresh/a"
make_old "${PODS}/Pods-old"
pod_output=$(
    pod() { return 0 }
    _MAC_OPS_FC_RUNNING_EXECS="${IDLE_PROCESSES}"
    _MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder"
    _mac_ops_dev_cocoapods 2>&1
)
assert_output_contains "${pod_output}" "Will move to trash: ${PODS}/Pods-old " "old CocoaPods item is moved"
assert_no_match "${pod_output}" "Will move to trash: ${PODS}/Pods-fresh " "fresh CocoaPods item is not moved"

# =============================================================================
# Running-app list failure protects everything (cache and orphan-app)
# =============================================================================
print "[TEST] cache_cleanup_lsappinfo_failure"
CACHES="${HOME}/Library/Caches"
mkdir -p "${CACHES}/com.macopstest.gone"
print "x" > "${CACHES}/com.macopstest.gone/blob"
make_old "${CACHES}/com.macopstest.gone"
for variant in fail empty; do
    cache_output=$(
        if [[ "${variant}" == "fail" ]]; then lsappinfo() { return 1 }; else lsappinfo() { return 0 }; fi
        require_stubs lsappinfo
        _MAC_OPS_FC_RUNNING_BUNDLES=""
        _MAC_OPS_FC_RUNNING_APPS_STATE=""
        _MAC_OPS_FC_RUNNING_EXECS="${IDLE_PROCESSES}"
        _MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder"
        mac_ops_cache_cleanup 2>&1
    )
    assert_no_match "${cache_output}" "Will move to trash" "lsappinfo ${variant}: cache-cleanup moves nothing"
    assert_output_contains "${cache_output}" "running-app list unavailable" "lsappinfo ${variant}: cache-cleanup warns"
done
cache_output=$(
    lsappinfo() { print -- '"Other" ASN:0x0-0x1: bundleID="com.example.running"'; return 0 }
    require_stubs lsappinfo
    _MAC_OPS_FC_RUNNING_BUNDLES=""
    _MAC_OPS_FC_RUNNING_APPS_STATE=""
    _MAC_OPS_FC_RUNNING_EXECS="${IDLE_PROCESSES}"
    _MAC_OPS_FC_OPEN_PATHS="n/nonexistent/placeholder"
    mac_ops_cache_cleanup 2>&1
)
assert_output_contains "${cache_output}" "Will move to trash: ${CACHES}/com.macopstest.gone " "control: with a working lsappinfo the old cache is moved"

print "[TEST] orphan_app_lsappinfo_failure"
OA_FX="${TEST_TMPDIR}/oa"
OA_ALL_APPS=$(find /Applications "${HOME}/Applications" /System/Applications -maxdepth 3 -name "*.app" -type d 2>/dev/null)
for variant in fail empty; do
    mkdir -p "${OA_FX}/${variant}/Caches/com.macopstest.orphan"
    print "x" > "${OA_FX}/${variant}/Caches/com.macopstest.orphan/blob"
    make_old "${OA_FX}/${variant}"
    (
        if [[ "${variant}" == "fail" ]]; then lsappinfo() { return 1 }; else lsappinfo() { return 0 }; fi
        mdfind() { print -r -- "${OA_ALL_APPS}"; return 0 }
        mdutil() { print -- "/:"; print -- "	Indexing enabled. "; return 0 }
        require_stubs lsappinfo mdfind mdutil
        MAC_OPS_ORPHAN_APP_SCAN_DIRS=("${OA_FX}/${variant}/Caches")
        MAC_OPS_DRY_RUN=false
        mac_ops_orphan_app_cleanup
    ) >/dev/null 2>&1
    assert_eq "$([[ -d "${OA_FX}/${variant}/Caches/com.macopstest.orphan" ]] && print yes || print no)" "yes" "lsappinfo ${variant}: orphan-app moves nothing"
done

# Control: with a working list the same fixture is moved, so the checks above
# are not passing for an unrelated reason
mkdir -p "${OA_FX}/ok/Caches/com.macopstest.orphan"
print "x" > "${OA_FX}/ok/Caches/com.macopstest.orphan/blob"
make_old "${OA_FX}/ok"
(
    lsappinfo() { print -- '"Other" ASN:0x0-0x1: bundleID="com.example.running"'; return 0 }
    mdfind() { print -r -- "${OA_ALL_APPS}"; return 0 }
    mdutil() { print -- "/:"; print -- "	Indexing enabled. "; return 0 }
    require_stubs lsappinfo mdfind mdutil
    MAC_OPS_ORPHAN_APP_SCAN_DIRS=("${OA_FX}/ok/Caches")
    MAC_OPS_DRY_RUN=false
    mac_ops_orphan_app_cleanup
) >/dev/null 2>&1
assert_eq "$([[ -d "${OA_FX}/ok/Caches/com.macopstest.orphan" ]] && print yes || print no)" "no" "control: with a working lsappinfo the orphan cache is moved"

# =============================================================================
# Orphan app: ~/Library/WebKit is data, reported not moved by default
# =============================================================================
print "[TEST] orphan_app_webkit_is_data"
mkdir -p "${OA_FX}/webkit/WebKit/com.macopstest.webapp/WebsiteData"
print "x" > "${OA_FX}/webkit/WebKit/com.macopstest.webapp/WebsiteData/LocalStorage"
make_old "${OA_FX}/webkit"
wk_output=$(
    require_stubs
    MAC_OPS_DRY_RUN=false
    unset MAC_OPS_ORPHAN_APP_DATA_ACTION
    source "${MAC_OPS_ROOT}/lib/modules/orphan-app-cleanup.zsh"
    _MAC_OPS_ORPHAN_APP_REPORT_ONLY=false
    typeset -gA _MAC_OPS_INSTALLED_BUNDLES _MAC_OPS_RUNNING_BUNDLES
    _MAC_OPS_INSTALLED_BUNDLES=(org.macopsinstalled.app 1)
    _MAC_OPS_RUNNING_BUNDLES=(com.example.running 1)
    _mac_ops_scan_directory "${OA_FX}/webkit/WebKit" 2>&1
)
assert_eq "$([[ -d "${OA_FX}/webkit/WebKit/com.macopstest.webapp" ]] && print yes || print no)" "yes" "WebKit orphan is not moved"
assert_output_contains "${wk_output}" "reported, not moved: ${OA_FX}/webkit/WebKit/com.macopstest.webapp (settings/data location" "WebKit orphan is reported as data"

# =============================================================================
# Brew: no cleanup while a running process uses a non-linked keg
# =============================================================================
print "[TEST] brew_old_keg_in_use"
BREW_PREFIX="${TEST_TMPDIR}/brew"
mkdir -p "${BREW_PREFIX}/Cellar/node/20.0.0/bin" "${BREW_PREFIX}/Cellar/node/22.0.0/bin" \
    "${BREW_PREFIX}/opt" "${BREW_PREFIX}/cache"
ln -s ../Cellar/node/22.0.0 "${BREW_PREFIX}/opt/node"
print "x" > "${BREW_PREFIX}/cache/blob"

# Usage: run_brew <ps output | __fail__>
run_brew() {
    : > "${CALLS}"
    (
        BREW_PS_OUT="${1}"
        brew() {
            print -r -- "brew $*" >> "${CALLS}"
            case "${1}" in
                --cache) print -r -- "${BREW_PREFIX}/cache" ;;
                --prefix) print -r -- "${BREW_PREFIX}" ;;
            esac
            return 0
        }
        ps() { [[ "${BREW_PS_OUT}" == "__fail__" ]] && return 1; print -r -- "${BREW_PS_OUT}"; return 0 }
        require_stubs brew ps
        MAC_OPS_DRY_RUN=false
        _MAC_OPS_FC_RUNNING_EXECS="${IDLE_PROCESSES}"
        mac_ops_brew_cleanup
    ) > "${TEST_TMPDIR}/brew-out" 2>&1
    grep "^brew cleanup" "${CALLS}"
}

calls=$(run_brew "${IDLE_PROCESSES}
${BREW_PREFIX}/Cellar/node/20.0.0/bin/node")
assert_eq "${calls}" "" "brew cleanup skipped while a process runs from an old keg"
assert_output_contains "$(cat "${TEST_TMPDIR}/brew-out")" "${BREW_PREFIX}/Cellar/node/20.0.0/bin/node uses keg node 20.0.0, linked: 22.0.0" "the holding process and keg are logged"
calls=$(run_brew "__fail__")
assert_eq "${calls}" "" "brew cleanup skipped when ps fails"
calls=$(run_brew "${IDLE_PROCESSES}
${BREW_PREFIX}/Cellar/node/22.0.0/bin/node")
assert_output_contains "${calls}" "brew cleanup --prune=7" "brew cleanup runs when only linked kegs are in use"

# =============================================================================
# Cleanup
# =============================================================================
mkdir -p "/tmp${TEST_TMPDIR:h}"
mv "${TEST_TMPDIR}" "/tmp${TEST_TMPDIR}" 2>/dev/null

print ""
print "Test results: ${TESTS_PASSED}/${TESTS_TOTAL} passed, ${TESTS_FAILED} failed"
[[ ${TESTS_FAILED} -eq 0 ]]
