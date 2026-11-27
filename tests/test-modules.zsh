#!/bin/zsh
# =============================================================================
# mac-ops: 모듈 통합 테스트 (dry-run 모드)
# =============================================================================
setopt NO_ERR_EXIT NO_PIPE_FAIL

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
export MAC_OPS_DRY_RUN=true
export MAC_OPS_VERBOSE=false
export MAC_OPS_FORCE=false
export MAC_OPS_SCHEDULED=true
export MAC_OPS_TRASH_RETENTION_HOURS=72

print "=== mac-ops 모듈 통합 테스트 (dry-run) ==="
print ""

# =============================================================================
# 전체 모듈 로딩 테스트
# =============================================================================
print "[TEST] module_loading"

local load_error=0

source "${MAC_OPS_ROOT}/lib/core/config.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/core/logger.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/core/lock.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/core/trash.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/core/safety.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/core/disk.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/utils/plist-helper.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/utils/format.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/utils/parallel.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/cache-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/tmp-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/log-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/zombie-killer.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/orphan-killer.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/orphan-app-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/brew-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/dev-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/docker-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/browser-cleanup.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/modules/analyze.zsh" 2>/dev/null || load_error=1
source "${MAC_OPS_ROOT}/lib/utils/notify.zsh" 2>/dev/null || load_error=1

assert_exit_code "${load_error}" "0" "all modules load without error"

# 디렉토리 초기화
mac_ops_init_dirs

# 전역 카운터 초기화
MAC_OPS_CLEANED_COUNT=0
MAC_OPS_CLEANED_BYTES=0
MAC_OPS_KILLED_COUNT=0

print ""

# =============================================================================
# test_cache_cleanup_dryrun
# =============================================================================
print "[TEST] test_cache_cleanup_dryrun"

mac_ops_cache_cleanup 2>/dev/null
assert_exit_code "$?" "0" "cache_cleanup in dry-run completes without error"

print ""

# =============================================================================
# test_tmp_cleanup_dryrun
# =============================================================================
print "[TEST] test_tmp_cleanup_dryrun"

mac_ops_tmp_cleanup 2>/dev/null
assert_exit_code "$?" "0" "tmp_cleanup in dry-run completes without error"

print ""

# =============================================================================
# test_log_cleanup_dryrun
# =============================================================================
print "[TEST] test_log_cleanup_dryrun"

mac_ops_log_cleanup 2>/dev/null
assert_exit_code "$?" "0" "log_cleanup in dry-run completes without error"

print ""

# =============================================================================
# test_zombie_killer_dryrun
# =============================================================================
print "[TEST] test_zombie_killer_dryrun"

mac_ops_zombie_killer 2>/dev/null
assert_exit_code "$?" "0" "zombie_killer in dry-run completes without error"

print ""

# =============================================================================
# test_orphan_killer_dryrun
# =============================================================================
print "[TEST] test_orphan_killer_dryrun"

mac_ops_orphan_killer 2>/dev/null
assert_exit_code "$?" "0" "orphan_killer in dry-run completes without error"

print ""

# =============================================================================
# test_orphan_app_cleanup_dryrun
# =============================================================================
print "[TEST] test_orphan_app_cleanup_dryrun"

mac_ops_orphan_app_cleanup 2>/dev/null
local orphan_app_exit=$?
# orphan_app_cleanup may return 1 if no bundles collected, which is OK
assert_eq "$((orphan_app_exit <= 1))" "1" "orphan_app_cleanup in dry-run completes (exit ${orphan_app_exit})"

print ""

# =============================================================================
# test_orphan_app_bundle_id_name
# A name without two literal dots is not a bundle ID and must never be scanned
# as orphan app data (regression: JetBrains, Naver, Garmin were trashed)
# =============================================================================
print "[TEST] test_orphan_app_bundle_id_name"

local _bid_name
for _bid_name in "JetBrains" "Naver" "Garmin" "iTerm2" "Google" "iCloud" "Sublime Text" "FaceTime" "a.b" "abcd"; do
  _mac_ops_is_bundle_id_name "${_bid_name}"
  assert_exit_code "$?" "1" "not a bundle ID name: ${_bid_name}"
done
for _bid_name in "com.example.app" "org.mozilla.firefox" "com.google.Chrome.helper" "io.github.some-tool"; do
  _mac_ops_is_bundle_id_name "${_bid_name}"
  assert_exit_code "$?" "0" "bundle ID name: ${_bid_name}"
done

print ""

# =============================================================================
# test_orphan_app_hardening
# Settings and data are reported instead of moved, a recently modified inner
# file protects an entry, security software is never touched, and a run without
# Spotlight results is report-only.
#
# Every scan below runs with dry-run OFF, so it happens inside a subshell that
# only ever sees fixture directories under TEST_TMPDIR. The dry-run flag of this
# test process is never changed. Results are asserted from the file system and
# the log file.
# =============================================================================
print "[TEST] test_orphan_app_hardening"

# --- Bundle ID pattern refinements ---
for _bid_name in "com.1password.1password" "org.7-zip.7zip" "com.foo_bar.app"; do
  _mac_ops_is_bundle_id_name "${_bid_name}"
  assert_exit_code "$?" "0" "bundle ID name: ${_bid_name}"
done
for _bid_name in "com.foo.bar baz" "a.b. " "com.foo." "1com.foo.bar"; do
  _mac_ops_is_bundle_id_name "${_bid_name}"
  assert_exit_code "$?" "1" "not a bundle ID name: '${_bid_name}'"
done

# --- Security software keyword safelist (case-insensitive, anywhere in the name) ---
local _kw_name
for _kw_name in "com.Fortinet.FortiClient" "com.wizvera.delfino" "net.nprotect.online" \
  "com.example.TouchEnKey" "com.AhnLab.v3" "com.example.ASTxHelper" "kr.veraport.agent" "com.example.PCAssist.agent"; do
  _mac_ops_is_security_keyword_name "${_kw_name}"
  assert_exit_code "$?" "0" "security keyword name: ${_kw_name}"
done
for _kw_name in "com.example.app" "org.mozilla.firefox" "com.macopstest.orphan"; do
  _mac_ops_is_security_keyword_name "${_kw_name}"
  assert_exit_code "$?" "1" "not a security keyword name: ${_kw_name}"
done

# --- Fixture helpers ---
local _oa_fx="${TEST_TMPDIR}/orphan-app-fixture"
local _oa_log="${MAC_OPS_LOG_DIR}/mac-ops.log"
local _oa_old_stamp
_oa_old_stamp=$(date -v-30d '+%Y%m%d%H%M')

# Create <dir>/sub/deep/data.bin with every level back-dated 30 days
_oa_make_dir_entry() {
  mkdir -p "${1}/sub/deep"
  print -- "data" > "${1}/sub/deep/data.bin"
  touch -t "${_oa_old_stamp}" "${1}/sub/deep/data.bin" "${1}/sub/deep" "${1}/sub" "${1}"
}

# Run one scanner against one fixture directory with dry-run off.
# Usage: _oa_scan <data_action> <report_only> <scan_dir>
# Writes the cleaned-item counter of the run to <fixture>/last-count.
_oa_scan() {
  (
    [[ "${3}" == "${TEST_TMPDIR}/"* && "${MAC_OPS_TRASH_DIR}" == "${TEST_TMPDIR}/"* ]] || exit 99
    MAC_OPS_DRY_RUN=false
    MAC_OPS_ORPHAN_APP_DATA_ACTION="${1}"
    _MAC_OPS_ORPHAN_APP_REPORT_ONLY="${2}"
    typeset -gA _MAC_OPS_INSTALLED_BUNDLES _MAC_OPS_RUNNING_BUNDLES
    _MAC_OPS_INSTALLED_BUNDLES=(com.macopstest.installed 1)
    _MAC_OPS_RUNNING_BUNDLES=()
    MAC_OPS_CLEANED_COUNT=0
    if [[ "${3}" == *"/Preferences" ]]; then
      _mac_ops_scan_preferences "${3}"
    else
      _mac_ops_scan_directory "${3}"
    fi
    print -- "${MAC_OPS_CLEANED_COUNT}" > "${_oa_fx}/last-count"
  ) >/dev/null 2>&1
}

# Run the whole module against one fixture directory with dry-run off and
# Spotlight replaced by a stub that prints <mdfind_output> (empty = no results).
# Usage: _oa_run_module <mdfind_output> <scan_dir>
_oa_run_module() {
  (
    [[ "${2}" == "${TEST_TMPDIR}/"* && "${MAC_OPS_TRASH_DIR}" == "${TEST_TMPDIR}/"* ]] || exit 99
    local _oa_mdfind_output="${1}"
    mdfind() { [[ -n "${_oa_mdfind_output}" ]] && print -- "${_oa_mdfind_output}"; return 0 }
    MAC_OPS_ORPHAN_APP_SCAN_DIRS=("${2}")
    MAC_OPS_ORPHAN_APP_DATA_ACTION=report
    MAC_OPS_DRY_RUN=false
    mac_ops_orphan_app_cleanup
  ) >/dev/null 2>&1
}

_oa_exists() { [[ -e "${1}" ]] && print -- "yes" || print -- "no" }
_oa_in_trash() { [[ -n "$(find "${MAC_OPS_TRASH_DIR}" -name "${1}" -print -quit 2>/dev/null)" ]] && print -- "yes" || print -- "no" }
_oa_logged() { grep -q -- "${1}" "${_oa_log}" 2>/dev/null && print -- "yes" || print -- "no" }

mkdir -p "${_oa_fx}"

# --- Data location: reported and not moved by default ---
local _oa_item="${_oa_fx}/report/Application Support/com.macopstest.reportdefault"
_oa_make_dir_entry "${_oa_item}"
_oa_scan report false "${_oa_fx}/report/Application Support"
assert_eq "$(_oa_exists "${_oa_item}")" "yes" "data location orphan is not moved by default"
assert_eq "$(cat "${_oa_fx}/last-count" 2>/dev/null)" "0" "reported orphan is not counted as cleaned"
assert_eq "$(_oa_logged "reported, not moved: .*com.macopstest.reportdefault")" "yes" "data location orphan is reported in the log"
assert_eq "$(_oa_logged "com.macopstest.reportdefault .*checks passed: not installed, not running, not safelisted, older than")" "yes" "report explains which checks the entry passed"

# An unknown value of the setting must behave like the default
_oa_scan "delete-everything" false "${_oa_fx}/report/Application Support"
assert_eq "$(_oa_exists "${_oa_item}")" "yes" "data location orphan is not moved with an unknown action value"

# --- Data location: moved when the user opts in ---
_oa_item="${_oa_fx}/optin/Application Support/com.macopstest.trashoptin"
_oa_make_dir_entry "${_oa_item}"
_oa_scan trash false "${_oa_fx}/optin/Application Support"
assert_eq "$(_oa_exists "${_oa_item}")" "no" "data location orphan is moved with DATA_ACTION=trash"
assert_eq "$(_oa_in_trash "com.macopstest.trashoptin")" "yes" "opted-in data location orphan is in the trash"
assert_eq "$(cat "${_oa_fx}/last-count" 2>/dev/null)" "1" "moved orphan is counted as cleaned"

# --- Preferences: same rule for plist files ---
_oa_item="${_oa_fx}/prefs/Preferences/com.macopstest.prefdefault.plist"
mkdir -p "${_oa_fx}/prefs/Preferences"
print -- "data" > "${_oa_item}"
touch -t "${_oa_old_stamp}" "${_oa_item}"
_oa_scan report false "${_oa_fx}/prefs/Preferences"
assert_eq "$(_oa_exists "${_oa_item}")" "yes" "orphan preference is not moved by default"
assert_eq "$(_oa_logged "reported, not moved: .*com.macopstest.prefdefault.plist")" "yes" "orphan preference is reported in the log"
_oa_scan trash false "${_oa_fx}/prefs/Preferences"
assert_eq "$(_oa_exists "${_oa_item}")" "no" "orphan preference is moved with DATA_ACTION=trash"

# --- Cache location: still moved by default ---
_oa_item="${_oa_fx}/cache/Caches/com.macopstest.cacheorphan"
_oa_make_dir_entry "${_oa_item}"
_oa_scan report false "${_oa_fx}/cache/Caches"
assert_eq "$(_oa_exists "${_oa_item}")" "no" "cache location orphan is still moved by default"
assert_eq "$(_oa_logged "com.macopstest.cacheorphan .*checks passed: not installed, not running, not safelisted, older than")" "yes" "move explains which checks the entry passed"

# --- A recently modified file deep inside protects the entry ---
_oa_item="${_oa_fx}/recent/Caches/com.macopstest.recentinner"
_oa_make_dir_entry "${_oa_item}"
touch "${_oa_item}/sub/deep/data.bin"
touch -t "${_oa_old_stamp}" "${_oa_item}/sub/deep" "${_oa_item}/sub" "${_oa_item}"
_oa_scan report false "${_oa_fx}/recent/Caches"
assert_eq "$(_oa_exists "${_oa_item}")" "yes" "entry with a recently modified inner file is not moved"

# --- Security software keyword protects the entry ---
_oa_item="${_oa_fx}/security/Caches/com.macopstest.astxhelper"
_oa_make_dir_entry "${_oa_item}"
_oa_scan trash false "${_oa_fx}/security/Caches"
assert_eq "$(_oa_exists "${_oa_item}")" "yes" "entry with a security software keyword is not moved"

# --- Report-only run: nothing is moved, not even from a cache location ---
_oa_item="${_oa_fx}/reportonly/Caches/com.macopstest.reportonly"
_oa_make_dir_entry "${_oa_item}"
_oa_scan trash true "${_oa_fx}/reportonly/Caches"
assert_eq "$(_oa_exists "${_oa_item}")" "yes" "report-only run does not move a cache location orphan"

# --- Whole module: Spotlight returning nothing makes the run report-only ---
_oa_item="${_oa_fx}/nospotlight/Caches/com.macopstest.nospotlight"
_oa_make_dir_entry "${_oa_item}"
_oa_run_module "" "${_oa_fx}/nospotlight/Caches"
assert_eq "$(_oa_exists "${_oa_item}")" "yes" "run without Spotlight results does not move a cache location orphan"
assert_eq "$(_oa_logged "Spotlight (mdfind) returned no applications")" "yes" "run without Spotlight results logs a warning"
assert_eq "$(_oa_logged "reported, not moved: .*com.macopstest.nospotlight")" "yes" "run without Spotlight results still reports the orphan"

# --- Whole module: with Spotlight results the cache location orphan is moved ---
_oa_item="${_oa_fx}/spotlight/Caches/com.macopstest.withspotlight"
_oa_make_dir_entry "${_oa_item}"
_oa_run_module "/System/Applications/Calculator.app" "${_oa_fx}/spotlight/Caches"
assert_eq "$(_oa_exists "${_oa_item}")" "no" "run with Spotlight results moves a cache location orphan"

unfunction _oa_make_dir_entry _oa_scan _oa_run_module _oa_exists _oa_in_trash _oa_logged

print ""

# =============================================================================
# test_brew_cleanup_dryrun
# =============================================================================
print "[TEST] test_brew_cleanup_dryrun"

mac_ops_brew_cleanup 2>/dev/null
local brew_exit=$?
# brew may not be installed; either 0 (success/skipped) or 1 (cache not found) is acceptable
assert_eq "$((brew_exit <= 1))" "1" "brew_cleanup in dry-run completes (exit ${brew_exit})"

print ""

# =============================================================================
# test_dev_cleanup_dryrun
# =============================================================================
print "[TEST] test_dev_cleanup_dryrun"

mac_ops_dev_cleanup 2>/dev/null
assert_exit_code "$?" "0" "dev_cleanup in dry-run completes without error"

print ""

# =============================================================================
# test_docker_cleanup_dryrun
# =============================================================================
print "[TEST] test_docker_cleanup_dryrun"

mac_ops_docker_cleanup 2>/dev/null
local docker_exit=$?
# docker may not be running; 0 is expected (skipped or dry-run preview)
assert_eq "$((docker_exit <= 1))" "1" "docker_cleanup in dry-run completes (exit ${docker_exit})"

print ""

# =============================================================================
# test_browser_cleanup_dryrun
# =============================================================================
print "[TEST] test_browser_cleanup_dryrun"

mac_ops_browser_cleanup 2>/dev/null
assert_exit_code "$?" "0" "browser_cleanup in dry-run completes without error"

print ""

# =============================================================================
# test_analyze
# =============================================================================
print "[TEST] test_analyze"

local analyze_output
analyze_output=$(mac_ops_analyze 2>/dev/null)
assert_exit_code "$?" "0" "analyze completes without error"
assert_output_contains "${analyze_output}" "Total Reclaimable Space" "analyze output contains total summary"

print ""

# =============================================================================
# test_notify
# =============================================================================
print "[TEST] test_notify"

# scheduled 모드에서 notify_completion 호출 (정리 항목 0이면 알림 안 함)
MAC_OPS_SCHEDULED=true
mac_ops_notify_completion "0" "0" "0" 2>/dev/null
assert_exit_code "$?" "0" "notify_completion with zero items returns 0"

# 정리 항목이 있으면 알림 시도 (osascript 실패해도 return 0)
mac_ops_notify_completion "5" "1048576" "2" 2>/dev/null
assert_exit_code "$?" "0" "notify_completion with items returns 0"

print ""

# =============================================================================
# test_cli_analyze
# =============================================================================
print "[TEST] test_cli_analyze"

local cli_analyze_output
cli_analyze_output=$("${MAC_OPS_ROOT}/bin/mac-ops" analyze 2>&1)
local cli_analyze_exit=$?

assert_exit_code "${cli_analyze_exit}" "0" "bin/mac-ops analyze exits 0"
assert_output_contains "${cli_analyze_output}" "Total Reclaimable Space" "analyze CLI output contains total summary"

print ""

# =============================================================================
# test_cli_help
# =============================================================================
print "[TEST] test_cli_help"

local help_output
help_output=$("${MAC_OPS_ROOT}/bin/mac-ops" help 2>&1)
local help_exit=$?

assert_exit_code "${help_exit}" "0" "bin/mac-ops help exits 0"
assert_output_contains "${help_output}" "mac-ops" "help output contains 'mac-ops'"

print ""

# =============================================================================
# test_cli_version
# =============================================================================
print "[TEST] test_cli_version"

local version_output
version_output=$("${MAC_OPS_ROOT}/bin/mac-ops" version 2>&1)
local version_exit=$?

assert_exit_code "${version_exit}" "0" "bin/mac-ops version exits 0"
assert_output_contains "${version_output}" "mac-ops v" "version output contains 'mac-ops v'"

print ""

# =============================================================================
# test_cli_dryrun
# =============================================================================
print "[TEST] test_cli_dryrun"

local dryrun_output
dryrun_output=$("${MAC_OPS_ROOT}/bin/mac-ops" run --dry-run 2>&1)
local dryrun_exit=$?

assert_exit_code "${dryrun_exit}" "0" "bin/mac-ops run --dry-run exits 0"

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
