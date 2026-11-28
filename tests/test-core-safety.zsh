#!/bin/zsh
# =============================================================================
# mac-ops: core safety tests (config loading, CLI precedence, module Enabled
# flags, settings registry)
# Everything runs with a throwaway HOME and every MAC_OPS_* directory inside a
# mktemp -d fixture. No real module runs: module functions are replaced by
# stubs, and bin/mac-ops is only called with the non-cleaning "config" and
# "status" commands.
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

# --- Project root ---
MAC_OPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- Fixture ---
TEST_TMPDIR=$(mktemp -d)
TEST_TMPDIR="${TEST_TMPDIR:A}"
if [[ -z "${TEST_TMPDIR}" || ! -d "${TEST_TMPDIR}" ]]; then
    print "[FAIL] cannot create fixture directory"
    exit 1
fi
FX_HOME="${TEST_TMPDIR}/home"
FX_OPS="${TEST_TMPDIR}/mac-ops-home"
mkdir -p "${FX_HOME}"

# Run a command with a clean environment: throwaway HOME and every MAC_OPS_*
# directory in the fixture. Extra VAR=value words may come first.
# Usage: fx_env [VAR=value ...] <command ...>
fx_env() {
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="${FX_HOME}" \
        MAC_OPS_HOME="${FX_OPS}" \
        MAC_OPS_TRASH_DIR="${FX_OPS}/.trash" \
        MAC_OPS_META_DIR="${FX_OPS}/.metadata" \
        MAC_OPS_LOG_DIR="${FX_OPS}/.logs" \
        MAC_OPS_LOCK_FILE="${FX_OPS}/mac-ops.lock" \
        MAC_OPS_CONFIG_FILE="${FX_CONFIG:-${FX_OPS}/config.plist}" \
        MAC_OPS_SCHEDULED=false \
        "$@"
}

# Source the core libraries in a fresh zsh (so the environment capture at
# source time is exercised) under ERR_EXIT, then run the given snippet.
# Usage: fx_zsh [VAR=value ...] -- '<zsh code>'
fx_zsh() {
    local -a envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    fx_env "${envs[@]}" zsh -f -c "
        setopt ERR_EXIT PIPE_FAIL
        MAC_OPS_ROOT='${MAC_OPS_ROOT}'
        source \"\${MAC_OPS_ROOT}/lib/core/config.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/core/logger.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/utils/parallel.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/core/dispatch.zsh\"
        $1"
}

reset_fixture() {
    rm -rf "${FX_OPS}"
    mkdir -p "${FX_OPS}"
}

CFG="${FX_OPS}/config.plist"

print "=== mac-ops core safety tests ==="
print ""

# =============================================================================
# 1. Missing keys never abort; an unparsable config aborts loudly
# =============================================================================
print "[TEST] config_missing_keys"

reset_fixture
# The config.plist shipped before this change lacks Verbose, Force and most
# module keys; reading any missing key used to exit under ERR_EXIT
git -C "${MAC_OPS_ROOT}" show 87a3f2f:config/default.plist > "${CFG}" 2>/dev/null \
    || cp "${MAC_OPS_ROOT}/config/default.plist" "${CFG}"
out=$(fx_zsh -- 'mac_ops_load_config; print "reached verbose=${MAC_OPS_VERBOSE} force=${MAC_OPS_FORCE}"' 2>&1)
assert_output_contains "${out}" "reached verbose=false force=false" "old shipped default.plist: missing keys give defaults under ERR_EXIT"

cp "${MAC_OPS_ROOT}/config/default.plist" "${CFG}"
out=$(fx_zsh -- 'mac_ops_load_config; print "reached"' 2>&1)
assert_output_contains "${out}" "reached" "current config/default.plist loads under ERR_EXIT"
assert_output_not_contains "${out}" "WARN" "current config/default.plist has no invalid value"

plutil -create xml1 "${CFG}"
out=$(fx_zsh -- 'mac_ops_load_config; print "reached dry=${MAC_OPS_DRY_RUN} ret=${MAC_OPS_TRASH_RETENTION_HOURS}"' 2>&1)
assert_output_contains "${out}" "reached dry=false ret=72" "empty dict: every key falls back to its default"

out=$(fx_env zsh "${MAC_OPS_ROOT}/bin/mac-ops" config 2>&1); rc=$?
assert_eq "${rc}" "0" "bin/mac-ops config with an empty dict exits 0"
assert_output_contains "${out}" "MAC_OPS_TRASH_RETENTION_HOURS" "bin/mac-ops config with an empty dict prints settings"

print ""
print "[TEST] config_unparsable_aborts"

for kind in garbage array; do
    reset_fixture
    if [[ "${kind}" == "garbage" ]]; then
        print -r -- "<plist><dict><key>DryRun</key>" > "${CFG}"
    else
        # Valid property list, but its top level is an array, not a dictionary
        print -r -- '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><string>x</string></array></plist>' > "${CFG}"
    fi
    err=$(fx_env zsh "${MAC_OPS_ROOT}/bin/mac-ops" status 2>&1 >/dev/null); rc=$?
    assert_eq "$(( rc != 0 ))" "1" "${kind} config: status exits non-zero"
    assert_output_contains "${err}" "[ERROR] Cannot parse config file ${CFG}" "${kind} config: error on stderr"
    assert_output_contains "$(cat "${FX_OPS}/.logs/mac-ops.log" 2>/dev/null)" "[ERROR] Cannot parse config file" "${kind} config: error in the log file"
    out=$(fx_env zsh "${MAC_OPS_ROOT}/bin/mac-ops" config 2>&1); rc=$?
    assert_eq "$(( rc != 0 ))" "1" "${kind} config: config command exits non-zero"
    assert_output_not_contains "${out}" "=== Settings" "${kind} config: no settings printed from defaults"
done

reset_fixture
print -r -- "not a plist" > "${CFG}"
err=$(fx_env MAC_OPS_SCHEDULED=true zsh "${MAC_OPS_ROOT}/bin/mac-ops" status 2>&1 >/dev/null); rc=$?
assert_eq "$(( rc != 0 ))" "1" "scheduled mode: unparsable config exits non-zero"
assert_output_contains "${err}" "[ERROR] Cannot parse config file" "scheduled mode: error still reaches stderr"

print ""

# =============================================================================
# 2. Command-line flags win over config.plist
# =============================================================================
print "[TEST] cli_flags_win"

reset_fixture
plutil -create xml1 "${CFG}"
plutil -insert DryRun -bool false "${CFG}"
plutil -insert Verbose -bool false "${CFG}"
plutil -insert Force -bool false "${CFG}"
out=$(fx_env zsh "${MAC_OPS_ROOT}/bin/mac-ops" config --dry-run --verbose --force 2>&1)
assert_output_contains "${out}" "$(printf '%-42s = %-12s (%s' MAC_OPS_DRY_RUN true cli)" "--dry-run wins over DryRun=false"
assert_output_contains "${out}" "$(printf '%-42s = %-12s (%s' MAC_OPS_VERBOSE true cli)" "--verbose wins over Verbose=false"
assert_output_contains "${out}" "$(printf '%-42s = %-12s (%s' MAC_OPS_FORCE true cli)" "--force wins over Force=false"

out=$(fx_env MAC_OPS_DRY_RUN=false zsh "${MAC_OPS_ROOT}/bin/mac-ops" config --dry-run 2>&1)
assert_output_contains "${out}" "$(printf '%-42s = %-12s (%s' MAC_OPS_DRY_RUN true cli)" "--dry-run wins over MAC_OPS_DRY_RUN=false"

out=$(fx_zsh -- 'MAC_OPS_CLI_OVERRIDES[MAC_OPS_DRY_RUN]=true; mac_ops_load_config; mac_ops_load_config; print "dry=${MAC_OPS_DRY_RUN}"' 2>&1)
assert_output_contains "${out}" "dry=true" "CLI override survives repeated config loads"

print ""

# =============================================================================
# 3. Module Enabled flags
# =============================================================================
print "[TEST] module_enabled_flags"

STUBS='
for f in ${(v)MAC_OPS_MODULE_MAP}; do
  eval "${f}() { print -r -- ${f} >> \"${MAC_OPS_HOME}/ran\"; }"
done
mkdir -p "${MAC_OPS_HOME}/stats" "${MAC_OPS_LOG_DIR}"
: > "${MAC_OPS_HOME}/ran"
'
ran_list() { sort "${FX_OPS}/ran" 2>/dev/null | tr '\n' ' '; }
DEFAULT_RAN="mac_ops_cache_cleanup mac_ops_log_cleanup mac_ops_orphan_app_cleanup mac_ops_tmp_cleanup "

reset_fixture
out=$(fx_zsh -- "${STUBS}"'mac_ops_load_config; mac_ops_run_modules "" "${MAC_OPS_HOME}/stats"; print "rc=$?"' 2>&1)
assert_output_contains "${out}" "rc=0" "dispatcher returns 0"
assert_eq "$(ran_list)" "${DEFAULT_RAN}" "no config file: only trash-moving modules run"
for m in brew-cleanup dev-cleanup docker-cleanup browser-cleanup zombie-killer orphan-killer; do
    assert_eq "$(print -r -- "${out}" | grep -c "Module ${m} is disabled")" "1" "${m} disabled by default, logged exactly once"
done
assert_output_contains "${out}" "Modules.zombie-killer.Enabled to true in ${CFG}, or MAC_OPS_MODULE_ZOMBIE_KILLER_ENABLED=true" "disabled line says how to enable"

reset_fixture
cp "${MAC_OPS_ROOT}/config/default.plist" "${CFG}"
fx_zsh -- "${STUBS}"'mac_ops_load_config; mac_ops_run_modules "" "${MAC_OPS_HOME}/stats"' >/dev/null 2>&1
assert_eq "$(ran_list)" "${DEFAULT_RAN}" "shipped default.plist enables the same modules as the built-in defaults"

reset_fixture
plutil -create xml1 "${CFG}"
plutil -insert Modules -dictionary "${CFG}"
plutil -insert Modules.cache-cleanup -dictionary "${CFG}"
plutil -insert Modules.cache-cleanup.Enabled -bool false "${CFG}"
plutil -insert Modules.zombie-killer -dictionary "${CFG}"
plutil -insert Modules.zombie-killer.Enabled -bool true "${CFG}"
fx_zsh MAC_OPS_MODULE_LOG_CLEANUP_ENABLED=false -- "${STUBS}"'mac_ops_load_config; mac_ops_run_modules "" "${MAC_OPS_HOME}/stats"' >/dev/null 2>&1
assert_eq "$(ran_list)" "mac_ops_orphan_app_cleanup mac_ops_tmp_cleanup mac_ops_zombie_killer " "config.plist and env Enabled flags select the modules"

reset_fixture
out=$(fx_zsh -- "${STUBS}"'mac_ops_load_config; mac_ops_run_modules docker "${MAC_OPS_HOME}/stats"' 2>&1)
assert_eq "$(ran_list)" "mac_ops_docker_cleanup " "--module=docker runs the disabled module only"
assert_output_contains "${out}" "explicitly requested with --module=docker" "explicit run of a disabled module is logged"

reset_fixture
out=$(fx_zsh -- "${STUBS}"'mac_ops_load_config; mac_ops_run_modules nope "${MAC_OPS_HOME}/stats" || print "rc=$?"' 2>&1)
assert_output_contains "${out}" "rc=1" "unknown module returns 1"
assert_eq "$(ran_list)" "" "unknown module runs nothing"

print ""

# =============================================================================
# 4. Settings registry: precedence env > file > default, validation, listing
# =============================================================================
print "[TEST] settings_precedence"

reset_fixture
plutil -create xml1 "${CFG}"
plutil -insert TrashRetentionHours -integer 100 "${CFG}"
plutil -insert Modules -dictionary "${CFG}"
plutil -insert Modules.cache-cleanup -dictionary "${CFG}"
plutil -insert Modules.cache-cleanup.MaxAgeDays -integer 50 "${CFG}"
plutil -insert Modules.orphan-killer -dictionary "${CFG}"
plutil -insert Modules.orphan-killer.MinRunningHours -integer 48 "${CFG}"
plutil -insert Modules.orphan-killer.Action -string term "${CFG}"
plutil -insert Modules.docker-cleanup -dictionary "${CFG}"
plutil -insert Modules.docker-cleanup.PruneUntilHours -integer 100 "${CFG}"
out=$(fx_zsh MAC_OPS_CACHE_MAX_AGE_DAYS=40 MAC_OPS_ORPHAN_ACTION=report -- '
    source "${MAC_OPS_ROOT}/lib/core/safety.zsh"
    source "${MAC_OPS_ROOT}/lib/modules/orphan-killer.zsh"
    source "${MAC_OPS_ROOT}/lib/modules/docker-cleanup.zsh"
    mac_ops_load_config
    for v in MAC_OPS_CACHE_MAX_AGE_DAYS MAC_OPS_ORPHAN_ACTION MAC_OPS_TRASH_RETENTION_HOURS MAC_OPS_ORPHAN_MIN_RUNNING_HOURS MAC_OPS_DOCKER_PRUNE_UNTIL_HOURS MAC_OPS_TMP_MAX_AGE_DAYS MAC_OPS_ZOMBIE_ACTION; do
      print "${v}=${(P)v}/${MAC_OPS_SETTING_SOURCE[$v]}"
    done' 2>&1)
assert_output_contains "${out}" "MAC_OPS_CACHE_MAX_AGE_DAYS=40/env" "env beats file (cache MaxAgeDays)"
assert_output_contains "${out}" "MAC_OPS_ORPHAN_ACTION=report/env" "env beats file (orphan Action)"
assert_output_contains "${out}" "MAC_OPS_TRASH_RETENTION_HOURS=100/file" "file beats default (TrashRetentionHours)"
assert_output_contains "${out}" "MAC_OPS_ORPHAN_MIN_RUNNING_HOURS=48/file" "file value reaches the module after its source-time default (MinRunningHours)"
assert_output_contains "${out}" "MAC_OPS_DOCKER_PRUNE_UNTIL_HOURS=100/file" "file value reaches the module after its source-time default (docker)"
assert_output_contains "${out}" "MAC_OPS_TMP_MAX_AGE_DAYS=3/default" "default when neither env nor file (tmp MaxAgeDays)"
assert_output_contains "${out}" "MAC_OPS_ZOMBIE_ACTION=report/default" "default when neither env nor file (zombie Action)"

print ""
print "[TEST] settings_invalid_values"

reset_fixture
plutil -create xml1 "${CFG}"
plutil -insert TrashRetentionHours -string "soon" "${CFG}"
plutil -insert DryRun -string "maybe" "${CFG}"
plutil -insert Modules -dictionary "${CFG}"
plutil -insert Modules.tmp-cleanup -dictionary "${CFG}"
plutil -insert Modules.tmp-cleanup.MaxAgeDays -integer 0 "${CFG}"
out=$(fx_zsh MAC_OPS_ORPHAN_ACTION=kill MAC_OPS_ZOMBIE_ACTION=sigkill MAC_OPS_DOCKER_PROBE_TIMEOUT=-5 -- '
    mac_ops_load_config
    print "ret=${MAC_OPS_TRASH_RETENTION_HOURS} dry=${MAC_OPS_DRY_RUN} tmp=${MAC_OPS_TMP_MAX_AGE_DAYS} orphan=${MAC_OPS_ORPHAN_ACTION} zombie=${MAC_OPS_ZOMBIE_ACTION} probe=${MAC_OPS_DOCKER_PROBE_TIMEOUT}"' 2>&1)
assert_output_contains "${out}" "ret=72 dry=false tmp=3 orphan=report zombie=report probe=10" "invalid values fall back to the safe defaults"
assert_output_contains "${out}" "[WARN] Invalid value 'soon' for TrashRetentionHours" "non-integer in file is warned"
assert_output_contains "${out}" "[WARN] Invalid value '0' for Modules.tmp-cleanup.MaxAgeDays" "integer below minimum is warned"
assert_output_contains "${out}" "[WARN] Invalid value 'kill' for MAC_OPS_ORPHAN_ACTION" "enum outside allowed set (env) is warned"
assert_output_contains "${out}" "[WARN] Invalid value 'maybe' for DryRun" "non-boolean is warned"

print ""
print "[TEST] config_lists_every_setting"

reset_fixture
out=$(fx_env MAC_OPS_TMP_MAX_AGE_DAYS=4 zsh "${MAC_OPS_ROOT}/bin/mac-ops" config 2>&1)
names=$(fx_zsh -- 'for e in "${MAC_OPS_SETTINGS[@]}"; do print -r -- "${e%%|*}"; done' 2>/dev/null)
missing=""
for n in ${(f)names}; do
    [[ "${out}" == *"${n} "*"= "* ]] || missing+=" ${n}"
done
assert_eq "$(print -r -- "${names}" | grep -c .)" "39" "registry holds 39 settings"
assert_eq "${missing}" "" "mac-ops config lists every registry setting"
assert_output_contains "${out}" "$(printf '%-42s = %-12s (%s' MAC_OPS_TMP_MAX_AGE_DAYS 4 env)" "config shows env source"
assert_output_contains "${out}" "$(printf '%-42s = %-12s (%s' MAC_OPS_ORPHAN_ACTION report default)" "config shows default source"

# Every registry key is in the shipped default.plist with the default value
mism=""
for e in ${(f)"$(fx_zsh -- 'for e in "${MAC_OPS_SETTINGS[@]}"; do print -r -- "$e"; done' 2>/dev/null)"}; do
    key="${${e#*|}%%|*}"; def="${${${e#*|}#*|}%%|*}"
    [[ "$(plutil -extract "${key}" raw -o - "${MAC_OPS_ROOT}/config/default.plist" 2>/dev/null)" == "${def}" ]] || mism+=" ${key}"
done
assert_eq "${mism}" "" "config/default.plist lists every setting with its default"

print ""
# =============================================================================
# Trash nesting (item 5): libraries sourced into this shell, own fixture home
# =============================================================================
export HOME="${TEST_TMPDIR}/t5-home"
export MAC_OPS_HOME="${TEST_TMPDIR}/t5-ops"
export MAC_OPS_TRASH_DIR="${MAC_OPS_HOME}/.trash"
export MAC_OPS_META_DIR="${MAC_OPS_HOME}/.metadata"
export MAC_OPS_LOG_DIR="${MAC_OPS_HOME}/.logs"
export MAC_OPS_LOCK_FILE="${MAC_OPS_HOME}/mac-ops.lock"
export MAC_OPS_CONFIG_FILE="${MAC_OPS_HOME}/config.plist"
export MAC_OPS_DRY_RUN=false
export MAC_OPS_VERBOSE=true
export MAC_OPS_FORCE=false
export MAC_OPS_SCHEDULED=false
export MAC_OPS_TRASH_RETENTION_HOURS=72
# Fixture files are never open; do not depend on lsof here
export MAC_OPS_TRASH_SKIP_OPEN_DIRS=false
mkdir -p "${HOME}"

# --- Module loading ---
source "${MAC_OPS_ROOT}/lib/core/config.zsh"
source "${MAC_OPS_ROOT}/lib/core/logger.zsh"
source "${MAC_OPS_ROOT}/lib/core/lock.zsh"
source "${MAC_OPS_ROOT}/lib/core/trash.zsh"
source "${MAC_OPS_ROOT}/lib/core/safety.zsh"
source "${MAC_OPS_ROOT}/lib/core/disk.zsh"
source "${MAC_OPS_ROOT}/lib/utils/plist-helper.zsh"
source "${MAC_OPS_ROOT}/lib/utils/format.zsh"

mac_ops_init_dirs

PAST_ISO="2020-01-01T00:00:00Z"
FUTURE_ISO="2099-01-01T00:00:00Z"

# --- Helpers ---
# Empty the trash and its index
_t5_reset_trash() {
    # Settings this section depends on (independent of the file preamble)
    export MAC_OPS_DRY_RUN=false MAC_OPS_SCHEDULED=false MAC_OPS_TRASH_SKIP_OPEN_DIRS=false
    rm -rf -- "${MAC_OPS_TRASH_DIR}"
    mkdir -p "${MAC_OPS_TRASH_DIR}"
    _mac_ops_index_reset
    mac_ops_index_write
}

# Key of the newest record for an original path ("" if none). Result in REPLY.
_t5_key_for() {
    local k
    REPLY=""
    mac_ops_index_read
    for k in "${_MAC_OPS_IDX_KEYS[@]}"; do
        [[ "${_MAC_OPS_IDX_ORIG[${k}]}" == "$1" ]] && REPLY="${k}"
    done
}

# Set expire_after of one record
_t5_set_expire() {
    mac_ops_index_read
    _MAC_OPS_IDX_EXPIRE[$1]="$2"
    mac_ops_index_write
}

# Add a record directly (simulates an index written by an older version)
_t5_add_record() {
    _MAC_OPS_IDX_KEYS+=("$1")
    _MAC_OPS_IDX_ORIG[$1]="$2"
    _MAC_OPS_IDX_TRASH[$1]="$3"
    _MAC_OPS_IDX_REASON[$1]="test"
    _MAC_OPS_IDX_MODULE[$1]="test-module"
    _MAC_OPS_IDX_TIME[$1]="2026-01-01T00:00:00Z"
    _MAC_OPS_IDX_SIZE[$1]=1
    _MAC_OPS_IDX_EXPIRE[$1]="$4"
}

_t5_record_count() {
    mac_ops_index_read
    REPLY=${#_MAC_OPS_IDX_KEYS[@]}
}

_t5_has_key() {
    mac_ops_index_read
    if [[ -n "${_MAC_OPS_IDX_ORIG[$1]+_}" ]]; then REPLY=yes; else REPLY=no; fi
}

print ""

# === Trash nesting (item 5) ===

# Trash X, recreate X/sub, trash it: the second entry must not land inside
# the first, and expiring only the first must keep sub and its record.
test_trash_nested_entry_survives_parent_expiry() {
    print "[TEST] test_trash_nested_entry_survives_parent_expiry"
    _t5_reset_trash
    local x="${TEST_TMPDIR}/files/X"
    mkdir -p "${x}"
    print "outer" > "${x}/outer.txt"
    mac_ops_trash_move "${x}" "test" "test-module" >/dev/null 2>&1
    _t5_key_for "${x}"; local key_x="${REPLY}"

    mkdir -p "${x}/sub"
    print "inner" > "${x}/sub/inner.txt"
    mac_ops_trash_move "${x}/sub" "test" "test-module" >/dev/null 2>&1
    _t5_key_for "${x}/sub"; local key_sub="${REPLY}"

    mac_ops_index_read
    local tp_x="${_MAC_OPS_IDX_TRASH[${key_x}]}"
    local tp_sub="${_MAC_OPS_IDX_TRASH[${key_sub}]}"
    local nested=no
    [[ "${tp_sub}" == "${tp_x}/"* ]] && nested=yes
    assert_eq "${nested}" "no" "re-trashed child is not placed inside the parent's entry"

    _t5_set_expire "${key_x}" "${PAST_ISO}"
    mac_ops_trash_expire >/dev/null 2>&1

    local content=""
    content=$(cat "${tp_sub}/inner.txt" 2>/dev/null)
    assert_eq "${content}" "inner" "child content survives the parent's expiry"
    _t5_has_key "${key_sub}"
    assert_eq "${REPLY}" "yes" "child record remains until its own expiry"
    _t5_has_key "${key_x}"
    assert_eq "${REPLY}" "no" "expired parent record is dropped"
    local gone=yes
    [[ -e "${tp_x}/outer.txt" ]] && gone=no
    assert_eq "${gone}" "yes" "expired parent content is deleted"
}

# An index from an older version with the child already nested inside the
# parent's entry: the parent is postponed while the child is live.
test_trash_nested_legacy_parent_postponed() {
    print "[TEST] test_trash_nested_legacy_parent_postponed"
    _t5_reset_trash
    local orig="${TEST_TMPDIR}/files/L"
    local tp="${MAC_OPS_TRASH_DIR}${orig}"
    mkdir -p "${tp}/sub"
    print "outer" > "${tp}/outer.txt"
    print "inner" > "${tp}/sub/inner.txt"
    mac_ops_index_read
    _t5_add_record "aaa_20260101000000" "${orig}" "${tp}" "${PAST_ISO}"
    _t5_add_record "bbb_20260101000001" "${orig}/sub" "${tp}/sub" "${FUTURE_ISO}"
    mac_ops_index_write

    local out
    out=$(mac_ops_trash_expire 2>&1)
    local content=""
    content=$(cat "${tp}/sub/inner.txt" 2>/dev/null)
    assert_eq "${content}" "inner" "nested live entry is not deleted with its expired parent"
    _t5_has_key "bbb_20260101000001"
    assert_eq "${REPLY}" "yes" "nested live record remains"
    _t5_has_key "aaa_20260101000000"
    assert_eq "${REPLY}" "yes" "postponed parent record is kept"
    assert_output_contains "${out}" "postponed" "postponement is logged"

    # Once the child expires too, both go
    _t5_set_expire "bbb_20260101000001" "${PAST_ISO}"
    mac_ops_trash_expire >/dev/null 2>&1
    local gone=yes
    [[ -e "${tp}" ]] && gone=no
    assert_eq "${gone}" "yes" "parent is deleted once nothing live is inside"
    _t5_record_count
    assert_eq "${REPLY}" "0" "both records dropped after both expired"
}

# Several records sharing one trash path: deleted only after the last expires
test_trash_shared_path_waits_for_last_record() {
    print "[TEST] test_trash_shared_path_waits_for_last_record"
    _t5_reset_trash
    local orig="${TEST_TMPDIR}/files/S"
    local tp="${MAC_OPS_TRASH_DIR}${orig}"
    mkdir -p "${tp}"
    print "shared" > "${tp}/data.txt"
    mac_ops_index_read
    _t5_add_record "ccc_20260101000000" "${orig}" "${tp}" "${PAST_ISO}"
    _t5_add_record "ccc_20260101000001" "${orig}" "${tp}" "${PAST_ISO}"
    _t5_add_record "ccc_20260101000002" "${orig}" "${tp}" "${FUTURE_ISO}"
    mac_ops_index_write

    mac_ops_trash_expire >/dev/null 2>&1
    local content=""
    content=$(cat "${tp}/data.txt" 2>/dev/null)
    assert_eq "${content}" "shared" "shared path survives while one record is live"
    _t5_record_count
    assert_eq "${REPLY}" "3" "all shared records kept while one is live"

    # Dry-run: nothing deleted, index unchanged
    _t5_set_expire "ccc_20260101000002" "${PAST_ISO}"
    MAC_OPS_DRY_RUN=true mac_ops_trash_expire >/dev/null 2>&1
    content=$(cat "${tp}/data.txt" 2>/dev/null)
    assert_eq "${content}" "shared" "dry-run deletes nothing"
    _t5_record_count
    assert_eq "${REPLY}" "3" "dry-run does not rewrite the index"

    mac_ops_trash_expire >/dev/null 2>&1
    local gone=yes
    [[ -e "${tp}" ]] && gone=no
    assert_eq "${gone}" "yes" "shared path deleted after the last record expired"
    _t5_record_count
    assert_eq "${REPLY}" "0" "all shared records dropped"
}

# A new move never reuses a path an index record still claims
test_trash_move_avoids_indexed_path() {
    print "[TEST] test_trash_move_avoids_indexed_path"
    _t5_reset_trash
    local orig="${TEST_TMPDIR}/files/R"
    local tp="${MAC_OPS_TRASH_DIR}${orig}"
    mac_ops_index_read
    _t5_add_record "ddd_20260101000000" "${orig}" "${tp}" "${FUTURE_ISO}"
    mac_ops_index_write
    mkdir -p "${orig}"
    print "new" > "${orig}/f.txt"
    mac_ops_trash_move "${orig}" "test" "test-module" >/dev/null 2>&1
    _t5_key_for "${orig}"; local new_key="${REPLY}"
    assert_eq "${new_key:+set}" "set" "moved item is indexed (orig)"
    mac_ops_index_read
    local new_tp="${_MAC_OPS_IDX_TRASH[${new_key}]}"
    local distinct=yes
    [[ "${new_tp}" == "${tp}" || "${new_tp}" == "${tp}/"* ]] && distinct=no
    assert_eq "${distinct}" "yes" "move does not reuse a path another record claims"

    # Destination above an indexed entry: P/c is indexed, P is trashed
    _t5_reset_trash
    local p="${TEST_TMPDIR}/files/P"
    mkdir -p "${p}/c"
    print "c" > "${p}/c/f.txt"
    mac_ops_trash_move "${p}/c" "test" "test-module" >/dev/null 2>&1
    mkdir -p "${p}"
    print "p" > "${p}/g.txt"
    mac_ops_trash_move "${p}" "test" "test-module" >/dev/null 2>&1
    _t5_key_for "${p}"; new_key="${REPLY}"
    assert_eq "${new_key:+set}" "set" "moved item is indexed (p)"
    mac_ops_index_read
    new_tp="${_MAC_OPS_IDX_TRASH[${new_key}]}"
    local above=no
    [[ "${MAC_OPS_TRASH_DIR}${p}/c" == "${new_tp}/"* ]] && above=yes
    assert_eq "${above}" "no" "move is not placed above an indexed entry"
}

# A record whose trash path no longer exists is dropped with a log line
test_trash_missing_path_record_dropped() {
    print "[TEST] test_trash_missing_path_record_dropped"
    _t5_reset_trash
    local orig="${TEST_TMPDIR}/files/M"
    mac_ops_index_read
    _t5_add_record "eee_20260101000000" "${orig}" "${MAC_OPS_TRASH_DIR}${orig}" "${FUTURE_ISO}"
    mac_ops_index_write

    MAC_OPS_DRY_RUN=true mac_ops_trash_reconcile >/dev/null 2>&1
    _t5_has_key "eee_20260101000000"
    assert_eq "${REPLY}" "yes" "dry-run reconcile keeps the index unchanged"

    local out
    out=$(mac_ops_trash_reconcile 2>&1)
    _t5_has_key "eee_20260101000000"
    assert_eq "${REPLY}" "no" "record with a missing trash path is dropped"
    assert_output_contains "${out}" "no longer exists" "dropped record is logged"
}

test_trash_nested_entry_survives_parent_expiry
test_trash_nested_legacy_parent_postponed
test_trash_shared_path_waits_for_last_record
test_trash_move_avoids_indexed_path
test_trash_missing_path_record_dropped

print ""

# =============================================================================
# Self-protection (item 11): same in-shell environment as the trash section
# =============================================================================
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
    assert_refused "${HOME}/../${MAC_OPS_HOME:t}/.trash" "dotdot into mac-ops home refused"
}

test_selfprotect_companion_dirs() {
    print "[TEST] selfprotect_companion_dirs"
    assert_refused "${HOME}/.mac-optimize" ".mac-optimize refused"
    assert_refused "${HOME}/.mac-optimize/child/file.txt" "child of .mac-optimize refused"
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
    ln -sfn "${MAC_OPS_HOME}" "${TEST_TMPDIR}/link-to-home"
    assert_refused "${TEST_TMPDIR}/link-to-home/.trash" "symlink into mac-ops home refused"
}

test_selfprotect_allows_ordinary() {
    print "[TEST] selfprotect_allows_ordinary"
    mkdir -p "${HOME}/Library/Caches/com.example.app"
    mac_ops_is_path_safe "${HOME}/Library/Caches/com.example.app" >/dev/null 2>&1
    assert_eq "$?" "0" "ordinary cache path allowed"
    mac_ops_is_path_safe "/tmp/Usersfoo/x" >/dev/null 2>&1
    assert_eq "$?" "0" "/tmp/Usersfoo (prefix lookalike) allowed"
    mac_ops_is_path_safe "${MAC_OPS_HOME}-other/x" >/dev/null 2>&1
    assert_eq "$?" "0" "mac-ops home prefix lookalike allowed"
}

# mac_ops_trash_move itself refuses protected sources, so a module that does
# not call mac_ops_is_path_safe cannot move them. Nothing is created outside
# the fixture: the /tmp parking paths are refused before any existence check,
# and only never-existing children of them are named (a regression must not
# move real parked items into the fixture trash).
test_selfprotect_trash_move_refuses() {
    print "[TEST] selfprotect_trash_move_refuses"
    _t5_reset_trash
    mkdir -p "${MAC_OPS_HOME}/sub" "${HOME}/.mac-optimize/rec"
    print "keep" > "${MAC_OPS_HOME}/sub/f.txt"
    print "keep" > "${HOME}/.mac-optimize/rec/f.txt"
    ln -sfn "${MAC_OPS_HOME}" "${TEST_TMPDIR}/link-to-home"
    local p out rc nx="mac-ops-test-nonexistent-$$-${RANDOM}"
    for p in "${MAC_OPS_HOME}/sub" "${MAC_OPS_HOME}/sub/f.txt" "${MAC_OPS_LOG_DIR}" \
             "${HOME}/.mac-optimize" "${HOME}/.mac-optimize/rec" \
             "${TEST_TMPDIR}/link-to-home/sub" \
             /tmp/{Users,Library,Applications,usr,opt,private}/"${nx}" \
             /private/tmp/{Users,Library,Applications,usr,opt,private}/"${nx}"; do
        out=$(mac_ops_trash_move "${p}" "test" "test-module" 2>&1); rc=$?
        assert_eq "${rc}" "1" "trash_move refuses ${p}"
        assert_output_contains "${out}" "[WARN] Not moved, protected path" "refusal of ${p} logged at WARN"
    done
    assert_eq "$(cat "${MAC_OPS_HOME}/sub/f.txt" 2>/dev/null)" "keep" "mac-ops home content untouched"
    assert_eq "$(cat "${HOME}/.mac-optimize/rec/f.txt" 2>/dev/null)" "keep" ".mac-optimize content untouched"
    _t5_record_count
    assert_eq "${REPLY}" "0" "nothing indexed for refused moves"
}

test_selfprotect_mac_ops_home
test_selfprotect_companion_dirs
test_selfprotect_tmp_parking_dirs
test_selfprotect_symlink
test_selfprotect_allows_ordinary
test_selfprotect_trash_move_refuses

print ""

# =============================================================================
# Loud data moves (item 7): settings/app-data areas are WARNed and counted
# =============================================================================
test_data_move_logged_and_counted() {
    print "[TEST] data_move_logged_and_counted"
    _t5_reset_trash
    local src="${HOME}/Library/Application Support/X"
    mkdir -p "${src}" "${HOME}/Library/Caches/com.example.data"
    print "settings" > "${src}/prefs.json"
    print "cache" > "${HOME}/Library/Caches/com.example.data/c.bin"
    MAC_OPS_DATA_MOVED_COUNT=0
    local log_before=0
    [[ -f "${MAC_OPS_LOG_FILE}" ]] && log_before=$(wc -l < "${MAC_OPS_LOG_FILE}")
    mac_ops_trash_move "${src}" "orphan app data" "orphan-app-cleanup" >/dev/null 2>&1
    assert_eq "$?" "0" "move from Application Support succeeds"
    assert_eq "${MAC_OPS_DATA_MOVED_COUNT}" "1" "data move counted"
    local new_log
    new_log=$(tail -n +$((log_before + 1)) "${MAC_OPS_LOG_FILE}" 2>/dev/null)
    assert_output_contains "${new_log}" "[WARN] Moved settings/app data to trash: ${src} (module: orphan-app-cleanup, reason: orphan app data)" "data move logged at WARN with module and reason"

    mac_ops_trash_move "${HOME}/Library/Caches/com.example.data" "cache-expired" "cache-cleanup" >/dev/null 2>&1
    assert_eq "${MAC_OPS_DATA_MOVED_COUNT}" "1" "cache move is not counted as data"

    mkdir -p "${HOME}/Library/Preferences/p.d"
    MAC_OPS_DRY_RUN=true mac_ops_trash_move "${HOME}/Library/Preferences/p.d" "test" "test-module" >/dev/null 2>&1
    assert_eq "${MAC_OPS_DATA_MOVED_COUNT}" "2" "dry-run data move counted too"
    assert_eq "$([[ -d "${HOME}/Library/Preferences/p.d" ]] && print kept)" "kept" "dry-run moves nothing"

    local out
    out=$(mac_ops_print_report "10 1000 0 0" "10 1000 0 0" "3" "100" "0" "2")
    assert_output_contains "${out}" "2 data items moved" "run summary shows data items moved"
}

test_data_move_count_survives_parallel_stats() {
    print "[TEST] data_move_count_survives_parallel_stats"
    reset_fixture
    local out
    out=$(fx_zsh -- '
        for f in ${(v)MAC_OPS_MODULE_MAP}; do eval "${f}() { :; }"; done
        mac_ops_cache_cleanup() { MAC_OPS_CLEANED_COUNT=3; MAC_OPS_DATA_MOVED_COUNT=2; }
        mac_ops_tmp_cleanup() { MAC_OPS_DATA_MOVED_COUNT=1; }
        mkdir -p "${MAC_OPS_HOME}/stats" "${MAC_OPS_LOG_DIR}"
        MAC_OPS_CLEANED_COUNT=0 MAC_OPS_CLEANED_BYTES=0 MAC_OPS_DATA_MOVED_COUNT=0
        mac_ops_load_config
        mac_ops_run_modules "" "${MAC_OPS_HOME}/stats" >/dev/null 2>&1
        print "count=${MAC_OPS_CLEANED_COUNT} data=${MAC_OPS_DATA_MOVED_COUNT}"' 2>&1)
    assert_output_contains "${out}" "count=3 data=3" "data-moved count from parallel modules is summed via stats files"
}

test_data_move_logged_and_counted
test_data_move_count_survives_parallel_stats

print ""

# =============================================================================
# Honest numbers (item 10): trashed bytes are not "freed"; real df change
# =============================================================================
source "${MAC_OPS_ROOT}/lib/utils/notify.zsh"

test_report_wording_honest() {
    print "[TEST] report_wording_honest"
    local out
    out=$(MAC_OPS_TRASH_RETENTION_HOURS=48 mac_ops_print_report "10 5000000 0 0" "10 5000000 0 0" "4" "2097152" "0" "0")
    assert_output_contains "${out}" "4 items (2.0 MB) moved to trash (purged after 48 hours)" "summary says moved to trash with the retention setting"
    assert_output_not_contains "${out}" "cleaned:" "summary no longer says files cleaned"
    assert_output_contains "${out}" "free space not increased yet (space is reclaimed when the trash is purged)" "zero df change: reclaimed at purge"
    out=$(mac_ops_print_report "10 5000000 0 0" "10 4000000 0 0" "1" "10" "0")
    assert_output_contains "${out}" "free space not increased yet" "negative df change: reclaimed at purge"
    out=$(mac_ops_print_report "10 1048576 0 0" "9 4194304 0 0" "1" "10" "0")
    assert_output_contains "${out}" "free space +3.0 MB" "positive df change reported separately"
    out=$(MAC_OPS_DRY_RUN=true mac_ops_print_report "10 1 0 0" "10 1 0 0" "2" "10" "0")
    assert_output_contains "${out}" "would be moved to trash (dry run)" "dry-run summary does not claim a move"
}

test_notify_message_honest() {
    print "[TEST] notify_message_honest"
    local msg
    msg=$(MAC_OPS_TRASH_RETENTION_HOURS=72 mac_ops_notify_message "5" "1048576" "2" "1000000" "1000000" "1")
    assert_output_contains "${msg}" "5 items (1.0 MB) moved to trash (purged after 72 hours)" "notification says moved to trash"
    assert_output_contains "${msg}" "1 data items moved" "notification includes data items moved"
    assert_output_contains "${msg}" "2 processes terminated" "notification includes terminated processes"
    assert_output_contains "${msg}" "space is reclaimed when the trash is purged" "notification: no df gain, reclaimed at purge"
    assert_output_not_contains "${msg}" "freed" "notification never says freed"
    msg=$(mac_ops_notify_message "1" "10" "0" "1048576" "3145728" "0")
    assert_output_contains "${msg}" "free space +2.0 MB" "notification reports real df gain"
    msg=$(mac_ops_notify_message "0" "0" "0" "1" "1" "0")
    assert_eq "${msg}" "" "nothing to report: empty message"
}

test_report_wording_honest
test_notify_message_honest

# --- Teardown ---
rm -rf "${TEST_TMPDIR}"

# --- Result summary ---
print "========================================="
print "Test results: ${TESTS_PASSED}/${TESTS_TOTAL} passed, ${TESTS_FAILED} failed"
print "========================================="

if [[ ${TESTS_FAILED} -gt 0 ]]; then
    exit 1
fi
exit 0
