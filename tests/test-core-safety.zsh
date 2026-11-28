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
print "[TEST] settings_invalid_env_falls_through"

# An invalid environment value must not skip config.plist (garbage
# MAC_OPS_DRY_RUN with DryRun=true in the file used to give a real run)
reset_fixture
plutil -create xml1 "${CFG}"
plutil -insert DryRun -bool true "${CFG}"
plutil -insert TrashRetentionHours -string "soon" "${CFG}"
out=$(fx_zsh MAC_OPS_DRY_RUN=garbage MAC_OPS_TRASH_RETENTION_HOURS=bad MAC_OPS_ORPHAN_ACTION=kill -- '
    mac_ops_load_config
    print "dry=${MAC_OPS_DRY_RUN}/${MAC_OPS_SETTING_SOURCE[MAC_OPS_DRY_RUN]} ret=${MAC_OPS_TRASH_RETENTION_HOURS}/${MAC_OPS_SETTING_SOURCE[MAC_OPS_TRASH_RETENTION_HOURS]} orphan=${MAC_OPS_ORPHAN_ACTION}/${MAC_OPS_SETTING_SOURCE[MAC_OPS_ORPHAN_ACTION]}"' 2>&1)
assert_output_contains "${out}" "dry=true/file" "invalid env value falls through to the config file value (DryRun)"
assert_output_contains "${out}" "ret=72/default" "invalid env and invalid file value give the default"
assert_output_contains "${out}" "orphan=report/default" "invalid env value without a file value gives the default"
assert_output_contains "${out}" "[WARN] Invalid value 'garbage' for MAC_OPS_DRY_RUN" "invalid env value is warned"
assert_output_contains "${out}" "[WARN] Invalid value 'soon' for TrashRetentionHours" "invalid file value after an invalid env value is warned"
assert_output_contains "${out}" "MAC_OPS_TRASH_RETENTION_HOURS: no valid value set, using default '72'" "fallback to the default is warned"
assert_output_not_contains "${out}" "MAC_OPS_DRY_RUN: no valid value set" "no default warning when the file value is used"

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

print ""

# =============================================================================
# Failure notification (item 12): osascript is replaced by a recording stub
# =============================================================================
OSA_CALLS="${TEST_TMPDIR}/osascript.calls"
osascript() { print -r -- "$*" >> "${OSA_CALLS}"; }

_t12_run_end() {
    : > "${OSA_CALLS}"
    MAC_OPS_CLEANED_COUNT=0 MAC_OPS_CLEANED_BYTES=0 MAC_OPS_KILLED_COUNT=0 MAC_OPS_DATA_MOVED_COUNT=0
    MAC_OPS_SCHEDULED=true mac_ops_notify_run_end "$1" "$2" 1000 1000
}

test_failure_notification() {
    print "[TEST] failure_notification"
    local start calls
    mkdir -p "${MAC_OPS_LOG_DIR}"

    # ERROR from a parallel module subshell, zero items, exit status 0
    mac_ops_log_line_count; start="${REPLY}"
    ( MAC_OPS_SCHEDULED=true; mac_ops_log_error "module failed: boom"; mac_ops_log_warn "something odd" )
    _t12_run_end "${start}" 0
    calls=$(cat "${OSA_CALLS}")
    assert_output_contains "${calls}" "Mac-Ops Run Had Errors" "ERROR with zero items: notification sent"
    assert_output_contains "${calls}" "1 errors, 1 warnings logged" "notification counts ERROR and WARN lines since run start"

    # Clean zero-item run (INFO only): no notification
    mac_ops_log_line_count; start="${REPLY}"
    ( MAC_OPS_SCHEDULED=true; mac_ops_log_info "all fine" )
    _t12_run_end "${start}" 0
    assert_eq "$(grep -c . "${OSA_CALLS}")" "0" "clean zero-item run: no notification"

    # Non-zero exit status without an ERROR line
    mac_ops_log_line_count; start="${REPLY}"
    _t12_run_end "${start}" 1
    assert_output_contains "$(cat "${OSA_CALLS}")" "Run failed (exit status 1)" "non-zero exit: notification sent"

    # Interactive (not scheduled) runs never call osascript
    : > "${OSA_CALLS}"
    MAC_OPS_SCHEDULED=false mac_ops_notify_run_end 0 1 >/dev/null 2>&1
    assert_eq "$(grep -c . "${OSA_CALLS}")" "0" "interactive run: no notification"
}

test_failure_notification
unset -f osascript

# =============================================================================
# Run lock and exit handling: the lock is held for the whole run and every
# way a run ends (normal, ERR_EXIT abort, TERM) finishes it once
# =============================================================================
print "[TEST] run_lock_and_exit_handling"

# Run snippet in a fresh zsh under ERR_EXIT with lock/run/notify loaded and
# osascript replaced by a recording stub (never the real one)
_ta_run() {
    fx_zsh MAC_OPS_SCHEDULED=true -- "
        source \"\${MAC_OPS_ROOT}/lib/core/lock.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/core/trash.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/core/run.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/utils/format.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/utils/notify.zsh\"
        osascript() { print -r -- \"\$*\" >> '${FX_OPS}/osa.calls'; }
        mac_ops_init_dirs
        mac_ops_run_start
        mac_ops_setup_trap
        mac_ops_acquire_lock
        _MAC_OPS_RUN_LOCKED=true
        $1"
}
TA_LOG="${FX_OPS}/.logs/mac-ops.log"

test_run_lock_held() {
    reset_fixture
    local out
    # Setting up the traps again while the lock is held (the old function
    # released it on return through a function-scoped EXIT trap)
    out=$(_ta_run 'mac_ops_setup_trap
        f() { return 0; }; f
        [[ -f "${MAC_OPS_LOCK_FILE}" ]] && print "LOCK_HELD_AFTER_SETUP"
        mac_ops_run_finish 0
        [[ -f "${MAC_OPS_LOCK_FILE}" ]] || print "LOCK_RELEASED_AT_FINISH"' 2>&1)
    assert_output_contains "${out}" "LOCK_HELD_AFTER_SETUP" "lock still held after mac_ops_setup_trap returns"
    assert_output_contains "${out}" "LOCK_RELEASED_AT_FINISH" "lock released by mac_ops_run_finish"
    assert_output_not_contains "$(cat "${TA_LOG}" 2>/dev/null)" "[WARN]" "normal run: no spurious WARN"
    assert_output_not_contains "$(cat "${TA_LOG}" 2>/dev/null)" "aborted" "normal run: not logged as aborted"
    assert_output_not_contains "$(cat "${FX_OPS}/osa.calls" 2>/dev/null)" "Run failed" "normal run: no failure notification"
}

test_run_errexit_abort() {
    reset_fixture
    local rc=0
    _ta_run 'g() { false; print "NOT_REACHED"; }; g' >/dev/null 2>&1 || rc=$?
    assert_eq "${rc}" "1" "ERR_EXIT abort: exit status 1"
    assert_eq "$([[ -e "${FX_OPS}/mac-ops.lock" ]] && print held || print released)" "released" "ERR_EXIT abort: lock released"
    assert_output_contains "$(cat "${TA_LOG}" 2>/dev/null)" "Run aborted (command failed, exit status 1)" "ERR_EXIT abort: failure logged"
    assert_output_contains "$(cat "${FX_OPS}/osa.calls" 2>/dev/null)" "Run failed (exit status 1)" "ERR_EXIT abort: scheduled failure notification sent"
    assert_output_contains "$(cat "${FX_OPS}"/runs/*.json 2>/dev/null)" '"exit_status": 1,' "ERR_EXIT abort: manifest records the failure"
}

test_run_errexit_ignored_where_off() {
    reset_fixture
    local out
    out=$(_ta_run 'h() { setopt LOCAL_OPTIONS NO_ERR_EXIT; false; print "H_CONTINUES"; }; h
        ( false ) || true
        [[ -f "${MAC_OPS_LOCK_FILE}" ]] && print "LOCK_STILL_HELD"
        mac_ops_run_finish 0' 2>&1)
    assert_output_contains "${out}" "H_CONTINUES" "failure in a NO_ERR_EXIT function does not abort"
    assert_output_contains "${out}" "LOCK_STILL_HELD" "failure in NO_ERR_EXIT function / subshell keeps the lock"
    assert_output_not_contains "$(cat "${TA_LOG}" 2>/dev/null)" "aborted" "no abort logged for handled failures"
}

test_run_term_signal() {
    reset_fixture
    local rc=0
    _ta_run 'kill -TERM $$; sleep 1; print "NOT_REACHED"' >/dev/null 2>&1 || rc=$?
    assert_eq "${rc}" "143" "TERM: exit status 143"
    assert_eq "$([[ -e "${FX_OPS}/mac-ops.lock" ]] && print held || print released)" "released" "TERM: lock released"
    assert_output_contains "$(cat "${TA_LOG}" 2>/dev/null)" "Run aborted (signal TERM, exit status 143)" "TERM: logged once"
    assert_eq "$(grep -c "Run aborted" "${TA_LOG}" 2>/dev/null)" "1" "TERM: finished exactly once"
    assert_output_contains "$(cat "${FX_OPS}/osa.calls" 2>/dev/null)" "Run failed (exit status 143)" "TERM: scheduled failure notification sent"
}

test_run_explicit_exit() {
    reset_fixture
    local rc=0
    _ta_run 'exit 3' >/dev/null 2>&1 || rc=$?
    assert_eq "${rc}" "3" "explicit exit: status kept"
    assert_eq "$([[ -e "${FX_OPS}/mac-ops.lock" ]] && print held || print released)" "released" "explicit exit: lock released"
}

test_run_lock_held
test_run_errexit_abort
test_run_errexit_ignored_where_off
test_run_term_signal

# Run lock: stale detection by PID plus process start time, atomic acquire
_tl_lock() {
    fx_zsh -- "
        source \"\${MAC_OPS_ROOT}/lib/core/lock.zsh\"
        mac_ops_init_dirs
        $1"
}
_tl_start_of() {
    _tl_lock "_mac_ops_lock_pid_start $1 && print -r -- \"\${REPLY}\"" 2>/dev/null
}

test_run_lock_stale_and_live() {
    reset_fixture
    local out rc lock="${FX_OPS}/mac-ops.lock" me_start
    me_start=$(_tl_start_of $$)
    assert_eq "${me_start//[0-9]/}" "" "start time of a live PID is read (digits only)"

    # PID reused: the PID is alive (this test shell) but started at another time
    print -r -- "$$ 12345" > "${lock}"
    out=$(_tl_lock 'rc=0; mac_ops_acquire_lock || rc=$?; print "rc=${rc} holder=$(cut -d" " -f1 "${MAC_OPS_LOCK_FILE}") self=${sysparams[pid]}"' 2>&1)
    assert_output_contains "${out}" "rc=0" "stale lock with a reused PID is cleared"
    [[ "${out}" =~ "holder=([0-9]+) self=([0-9]+)" ]] && assert_eq "${match[1]}" "${match[2]}" "new lock holds the acquiring PID"
    assert_output_contains "${out}" "Stale run lock" "reused PID logged as stale"

    # Live lock: this shell with its real start time, acquired from a subprocess
    print -r -- "$$ ${me_start}" > "${lock}"
    out=$(_tl_lock 'rc=0; mac_ops_acquire_lock || rc=$?; print "rc=${rc}"' 2>&1)
    assert_output_contains "${out}" "rc=1" "live lock blocks another run (return 1)"
    assert_eq "$(cat "${lock}")" "$$ ${me_start}" "live lock left untouched"

    # Dead PID
    print -r -- "999999 12345" > "${lock}"
    out=$(_tl_lock 'rc=0; mac_ops_acquire_lock || rc=$?; print "rc=${rc}"' 2>&1)
    assert_output_contains "${out}" "rc=0" "lock of a dead PID is cleared"

    # Legacy PID-only lock: live when the process started before the file was written
    print -r -- "$$" > "${lock}"
    out=$(_tl_lock 'rc=0; mac_ops_acquire_lock || rc=$?; print "rc=${rc}"' 2>&1)
    assert_output_contains "${out}" "rc=1" "legacy PID-only lock of a live run blocks"
    touch -t 200001010000 "${lock}"
    out=$(_tl_lock 'rc=0; mac_ops_acquire_lock || rc=$?; print "rc=${rc}"' 2>&1)
    assert_output_contains "${out}" "rc=0" "legacy PID-only lock older than its process (PID reused) is cleared"

    # Cannot create the lock: an error (2), not "another run"
    rm -f "${lock}"
    out=$(fx_env MAC_OPS_LOCK_FILE="${FX_OPS}/missing-dir/mac-ops.lock" zsh -f -c "
        MAC_OPS_ROOT='${MAC_OPS_ROOT}'
        source \"\${MAC_OPS_ROOT}/lib/core/config.zsh\"; source \"\${MAC_OPS_ROOT}/lib/core/logger.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/core/lock.zsh\"
        rc=0; mac_ops_acquire_lock || rc=\$?; print \"rc=\${rc}\"" 2>&1)
    assert_output_contains "${out}" "rc=2" "lock that cannot be created returns 2"
}

test_run_lock_race() {
    reset_fixture
    local lock="${FX_OPS}/mac-ops.lock" i
    print -r -- "999999 12345" > "${lock}"
    mkdir -p "${FX_OPS}/race"
    # Every child stays alive until all have tried, so no lock goes stale
    for i in 1 2 3 4 5; do
        _tl_lock "rc=0; mac_ops_acquire_lock || rc=\$?; print \${rc} > '${FX_OPS}/race/${i}'
            n=0; while [[ \$(ls '${FX_OPS}/race' | wc -l) -lt 5 && \$n -lt 100 ]]; do sleep 0.1; n=\$((n+1)); done
            sleep 0.5" >/dev/null 2>&1 &
    done
    wait
    assert_eq "$(cat "${FX_OPS}"/race/* | grep -c '^0$')" "1" "5 runs on one stale lock: exactly one wins"
    assert_eq "$(cat "${FX_OPS}"/race/* | grep -c '^1$')" "4" "5 runs on one stale lock: the others see a live run"
}

test_run_lock_subshell_and_or_true() {
    reset_fixture
    local out
    out=$(_ta_run '( mac_ops_release_lock )
        [[ -f "${MAC_OPS_LOCK_FILE}" ]] && print "LOCK_KEPT_BY_SUBSHELL_RELEASE"
        f() { false; print "F_CONTINUES"; }
        f || true
        [[ -f "${MAC_OPS_LOCK_FILE}" ]] && print "LOCK_KEPT_AFTER_OR_TRUE"
        mac_ops_run_finish 0
        [[ -f "${MAC_OPS_LOCK_FILE}" ]] || print "LOCK_RELEASED_AT_FINISH"' 2>&1)
    assert_output_contains "${out}" "LOCK_KEPT_BY_SUBSHELL_RELEASE" "a subshell cannot release the parent run lock"
    assert_output_contains "${out}" "F_CONTINUES" "failure inside 'func || true' does not abort under ERR_EXIT"
    assert_output_contains "${out}" "LOCK_KEPT_AFTER_OR_TRUE" "failure inside 'func || true' keeps the lock (no ZERR finish)"
    assert_output_contains "${out}" "LOCK_RELEASED_AT_FINISH" "lock released at finish"
    assert_output_not_contains "$(cat "${TA_LOG}" 2>/dev/null)" "aborted" "'func || true' failure: no abort logged"
}

# A run that finds another live run: no manifest, no notification, no move list
test_run_lock_collision_discard() {
    reset_fixture
    local out rc=0 me_start
    me_start=$(_tl_start_of $$)
    mkdir -p "${FX_OPS}"
    print -r -- "$$ ${me_start}" > "${FX_OPS}/mac-ops.lock"
    out=$(fx_zsh MAC_OPS_SCHEDULED=true -- "
        source \"\${MAC_OPS_ROOT}/lib/core/lock.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/core/trash.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/core/run.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/utils/format.zsh\"
        source \"\${MAC_OPS_ROOT}/lib/utils/notify.zsh\"
        osascript() { print -r -- \"\$*\" >> '${FX_OPS}/osa.calls'; }
        mac_ops_init_dirs
        mac_ops_run_start
        mac_ops_setup_trap
        [[ -f \"\${MAC_OPS_RUN_MOVES_FILE}\" ]] && print MOVES_CREATED
        lock_rc=0; mac_ops_acquire_lock || lock_rc=\$?
        print \"lock_rc=\${lock_rc}\"
        mac_ops_run_discard
        exit 0" 2>&1) || rc=$?
    assert_eq "${rc}" "0" "collision: exit 0"
    assert_output_contains "${out}" "lock_rc=1" "collision: acquire returns 1"
    assert_output_contains "${out}" "MOVES_CREATED" "collision: move list existed before the lock"
    assert_eq "$(ls "${FX_OPS}/runs" 2>/dev/null | grep -c .)" "0" "collision: no manifest written"
    assert_eq "$(ls "${FX_OPS}/.tmp" 2>/dev/null | grep -c 'moves$')" "0" "collision: move list removed"
    assert_eq "$(cat "${FX_OPS}/osa.calls" 2>/dev/null | grep -c .)" "0" "collision: no notification"
    assert_output_contains "$(cat "${TA_LOG}" 2>/dev/null)" "[INFO] Another mac-ops run is in progress" "collision: logged as INFO"
    assert_output_not_contains "$(cat "${TA_LOG}" 2>/dev/null)" "[ERROR]" "collision: no ERROR logged"
    assert_eq "$(cat "${FX_OPS}/mac-ops.lock")" "$$ ${me_start}" "collision: the other run's lock is untouched"
    # bin/mac-ops handles return 1 by discarding and exiting 0
    assert_output_contains "$(cat "${MAC_OPS_ROOT}/bin/mac-ops")" 'mac_ops_run_discard' "bin/mac-ops discards a colliding run"
}

test_run_lock_stale_and_live
test_run_lock_race
test_run_lock_subshell_and_or_true
test_run_lock_collision_discard
test_run_explicit_exit

# =============================================================================
# Run manifest, "runs" and "restore --run" (item 8)
# =============================================================================
print "[TEST] run_manifest_and_restore_run"
source "${MAC_OPS_ROOT}/lib/core/run.zsh"
source "${MAC_OPS_ROOT}/lib/utils/notify.zsh"

# Sourced libs in a fresh zsh under ERR_EXIT, same fixture environment
_tb_zsh() {
    zsh -f -c "
        setopt ERR_EXIT PIPE_FAIL
        MAC_OPS_ROOT='${MAC_OPS_ROOT}'
        for f in core/config core/logger core/lock core/trash core/safety core/run utils/format utils/notify; do
            source \"\${MAC_OPS_ROOT}/lib/\${f}.zsh\"
        done
        $1"
}

# Is a file valid JSON? (plutil parses JSON input)
_tb_json_ok() {
    plutil -convert xml1 -o /dev/null "$1" >/dev/null 2>&1 && print valid || print invalid
}

test_run_manifest() {
    _t5_reset_trash
    rm -rf -- "${MAC_OPS_HOME}/runs"
    local base="${HOME}/b8"
    local data_dir="${HOME}/Library/Application Support/B8App"
    rm -rf -- "${base}" "${data_dir}"
    mkdir -p "${base}" "${data_dir}"
    print a > "${base}/a.txt"
    print b > "${base}/b"$'\t'"tab.txt"
    print c > "${data_dir}/c.txt"

    mac_ops_run_start
    local run_id="${MAC_OPS_RUN_ID}"
    assert_eq "$([[ "${run_id}" =~ ^[0-9]{8}T[0-9]{6}-[0-9]+$ ]] && print ok)" "ok" "run ID is <timestamp>-<pid>"
    # Parallel subshells append to the same move list
    ( mac_ops_trash_move "${base}/a.txt" "test" "mod-a" >/dev/null 2>&1 ) &
    ( mac_ops_trash_move "${base}/b"$'\t'"tab.txt" "test" "mod-b" >/dev/null 2>&1 ) &
    wait
    mac_ops_trash_move "${data_dir}/c.txt" "test" "mod-a" >/dev/null 2>&1
    mac_ops_run_finish 0 >/dev/null 2>&1

    local manifest="${MAC_OPS_HOME}/runs/${run_id}.json"
    assert_eq "$([[ -f "${manifest}" ]] && print yes)" "yes" "manifest written to runs/<run-id>.json"
    assert_eq "$(_tb_json_ok "${manifest}")" "valid" "manifest is valid JSON (tab in a path escaped)"
    mac_ops_run_manifest_read "${manifest}"
    assert_eq "${MAC_OPS_MANIFEST[exit_status]}" "0" "manifest: exit status"
    assert_eq "${MAC_OPS_MANIFEST[items_moved]}" "3" "manifest: every move of the parallel subshells listed"
    assert_eq "${MAC_OPS_MANIFEST[data_items_moved]}" "1" "manifest: data item counted"
    assert_output_contains "$(cat "${manifest}")" '"mod-a": {"items": 2' "manifest: per-module counts"
    assert_output_contains "$(cat "${manifest}")" "\"original_path\": \"${data_dir}/c.txt\"" "manifest: moved path listed"
    assert_output_contains "$(cat "${manifest}")" '"free_kb_before": ' "manifest: free space before"
    assert_eq "$(ls "${MAC_OPS_HOME}/.tmp" 2>/dev/null | grep -c '\.moves$')" "0" "move list removed after the manifest is written"
    assert_eq "$(grep -c "\"run_id\": \"${run_id}\"" "${MAC_OPS_INDEX_FILE}")" "3" "index records carry the run ID"

    # runs lists it
    local out
    out=$(mac_ops_runs_list)
    assert_output_contains "${out}" "${run_id}" "runs lists the run"
    assert_output_contains "$(print -r -- "${out}" | grep "${run_id}")" " ok " "runs shows its status"

    # Dry-run restore changes nothing
    out=$(MAC_OPS_DRY_RUN=true _tb_zsh "mac_ops_trash_restore_run '${run_id}'" 2>&1)
    assert_output_contains "${out}" "3 would be restored" "restore --run --dry-run reports"
    assert_eq "$([[ -e "${base}/a.txt" ]] && print restored || print in-trash)" "in-trash" "restore --run --dry-run moves nothing"

    # One destination exists again: refused, the others restored, non-zero exit
    print new > "${base}/a.txt"
    local rc=0
    out=$(_tb_zsh "mac_ops_trash_restore_run '${run_id}'" 2>&1) || rc=$?
    assert_eq "${rc}" "1" "restore --run exits non-zero when an item is refused"
    assert_output_contains "${out}" "REFUSED (destination exists): ${base}/a.txt" "existing destination refused"
    assert_eq "$(cat "${base}/a.txt")" "new" "refused destination left untouched"
    assert_eq "$(cat "${data_dir}/c.txt" 2>/dev/null)" "c" "data item restored"
    assert_eq "$(cat "${base}/b"$'\t'"tab.txt" 2>/dev/null)" "b" "item with a tab in its name restored"
    assert_output_contains "${out}" "2 restored, 1 refused, 0 failed" "restore --run summary"

    # Again: restored items are no longer in the trash, nothing fails
    rm -f "${base}/a.txt"
    rc=0
    out=$(_tb_zsh "mac_ops_trash_restore_run '${run_id}'" 2>&1) || rc=$?
    assert_eq "${rc}" "0" "second restore --run succeeds"
    assert_output_contains "${out}" "1 restored, 0 refused, 0 failed, 2 no longer in the trash" "items already restored are reported, not failed"

    rc=0
    _tb_zsh "mac_ops_trash_restore_run '../etc/x'" >/dev/null 2>&1 || rc=$?
    assert_eq "${rc}" "1" "restore --run rejects a malformed run ID"
    rm -rf -- "${base}" "${data_dir}"
}

test_run_manifest_dry_run() {
    _t5_reset_trash
    rm -rf -- "${MAC_OPS_HOME}/runs" "${MAC_OPS_HOME}/.tmp"
    local base="${HOME}/b8dry"
    mkdir -p "${base}"; print x > "${base}/x.txt"
    (
        export MAC_OPS_DRY_RUN=true
        mac_ops_run_start
        mac_ops_trash_move "${base}/x.txt" "test" "mod-a" >/dev/null 2>&1
        mac_ops_run_finish 0 >/dev/null 2>&1
    )
    assert_eq "$(ls "${MAC_OPS_HOME}/runs" 2>/dev/null | wc -l | tr -d ' ')" "0" "dry-run: no manifest"
    assert_eq "$(ls "${MAC_OPS_HOME}/.tmp" 2>/dev/null | wc -l | tr -d ' ')" "0" "dry-run: no move list"
    assert_eq "$([[ -f "${base}/x.txt" ]] && print kept)" "kept" "dry-run: nothing moved"
    rm -rf -- "${base}"
}

test_run_manifest_retention() {
    rm -rf -- "${MAC_OPS_HOME}/runs"
    mkdir -p "${MAC_OPS_HOME}/runs"
    local i
    for i in 1 2 3 4 5; do
        print '{"run_id": "x"}' > "${MAC_OPS_HOME}/runs/2000010${i}T000000-1.json"
    done
    (
        MAC_OPS_RUNS_KEEP=3
        mac_ops_run_start
        mac_ops_run_finish 0 >/dev/null 2>&1
        print -r -- "${MAC_OPS_RUN_ID}" > "${MAC_OPS_HOME}/.last_id"
    )
    local -a left
    left=("${MAC_OPS_HOME}/runs"/*.json(N:t))
    assert_eq "${#left}" "3" "only the newest MAC_OPS_RUNS_KEEP manifests are kept"
    assert_eq "${left[-1]}" "$(cat "${MAC_OPS_HOME}/.last_id").json" "the new manifest is kept"
    assert_eq "${left[1]}" "20000104T000000-1.json" "the oldest manifests are removed"
    rm -f "${MAC_OPS_HOME}/.last_id"
}

test_run_manifest
test_run_manifest_dry_run
test_run_manifest_retention

# =============================================================================
# Status health (item 9): fixture manifests, injected launchctl check
# =============================================================================
print "[TEST] status_health"

TC_AGENTS="${TEST_TMPDIR}/agents"
TC_LOADED=""   # labels the stubbed launchctl check reports as loaded
_mac_ops_agent_loaded() { [[ " ${TC_LOADED} " == *" ${1} "* ]]; }

# Write a fixture manifest that ended <age> seconds ago
# Usage: _tc_manifest <age_seconds> <scheduled true|false> <exit_status> [errors warnings data]
_tc_manifest() {
    local now ended started id
    now=$(date +%s)
    ended=$(date -u -r $(( now - $1 )) '+%Y-%m-%dT%H:%M:%SZ')
    started=$(date -u -r $(( now - $1 - 30 )) '+%Y-%m-%dT%H:%M:%SZ')
    id="$(date -r $(( now - $1 - 30 )) '+%Y%m%dT%H%M%S')-$(( 1000 + $1 % 1000 ))"
    mkdir -p "${MAC_OPS_HOME}/runs"
    cat > "${MAC_OPS_HOME}/runs/${id}.json" <<JSON
{
  "version": 1,
  "run_id": "${id}",
  "scheduled": $2,
  "started": "${started}",
  "ended": "${ended}",
  "exit_status": $3,
  "errors": ${4:-0},
  "warnings": ${5:-0},
  "items_moved": 2,
  "data_items_moved": ${6:-0},
  "bytes_moved": 10,
  "modules": {},
  "moves": []
}
JSON
}

_tc_reset() {
    rm -rf -- "${MAC_OPS_HOME}/runs" "${TC_AGENTS}"
    mkdir -p "${TC_AGENTS}"
    cp "${MAC_OPS_ROOT}/launchd/com.mac-ops.cleanup.plist" "${TC_AGENTS}/com.mac-ops.cleanup.plist"
    TC_LOADED="com.mac-ops.cleanup"
}

test_health_failed_scheduled_run() {
    _tc_reset
    _tc_manifest 600 true 1 3 1 0
    local out
    out=$(mac_ops_run_health "${TC_AGENTS}")
    assert_output_contains "${out%%$'\n'*}" "[ALERT]" "failed scheduled run: alert on the first line"
    assert_output_contains "${out%%$'\n'*}" "FAILED (exit status 1, 3 errors)" "failed scheduled run: status and errors named"
    assert_output_contains "${out}" "Exit status:      1 (FAILED)" "failed scheduled run: exit status shown"
}

test_health_stale_agent() {
    _tc_reset
    _tc_manifest $(( 4 * 3600 )) true 0
    local out
    out=$(mac_ops_run_health "${TC_AGENTS}")
    assert_output_contains "${out%%$'\n'*}" "[ALERT] scheduled cleanup has not run for 4h (interval 60m" "stale agent (4h > 3 x 1h): alert on the first line"

    # A recent manual run does not hide an overdue schedule
    _tc_manifest 60 false 0
    out=$(mac_ops_run_health "${TC_AGENTS}")
    assert_output_contains "${out%%$'\n'*}" "has not run for 4h" "stale agent: still alerted after a manual run"
    assert_output_contains "${out}" "Last scheduled:" "stale agent: last scheduled run listed separately"

    # Calendar interval: daily (Hour) -> 4h is fine
    plutil -remove StartInterval "${TC_AGENTS}/com.mac-ops.cleanup.plist" >/dev/null 2>&1
    plutil -insert StartCalendarInterval -json '{"Hour": 3, "Minute": 0}' "${TC_AGENTS}/com.mac-ops.cleanup.plist" >/dev/null 2>&1
    _mac_ops_agent_interval "${TC_AGENTS}/com.mac-ops.cleanup.plist"
    assert_eq "${REPLY}" "86400" "StartCalendarInterval with Hour: one day"
    out=$(mac_ops_run_health "${TC_AGENTS}")
    assert_output_not_contains "${out}" "[ALERT]" "daily agent 4h after its run: no alert"
}

test_health_ok() {
    _tc_reset
    _tc_manifest 600 true 0 0 2 1
    local before after out
    before=$(ls -laR "${MAC_OPS_HOME}" 2>/dev/null | cksum)
    out=$(mac_ops_run_health "${TC_AGENTS}")
    after=$(ls -laR "${MAC_OPS_HOME}" 2>/dev/null | cksum)
    assert_eq "${out%%$'\n'*}" "=== Health ===" "healthy: no alert, health header first"
    assert_output_contains "${out}" "Exit status:      0 (ok)" "healthy: exit status"
    assert_output_contains "${out}" "0 errors, 2 warnings" "healthy: errors and warnings of the last run"
    assert_output_contains "${out}" "Data items moved: 1" "healthy: data items moved"
    assert_output_contains "${out}" "Agent com.mac-ops.cleanup: loaded" "healthy: agent loaded"
    assert_output_contains "${out}" "Agent com.mac-ops.monitor: not installed" "monitor agent state shown"
    assert_eq "${after}" "${before}" "health check writes nothing"

    # Installed but not loaded
    TC_LOADED=""
    out=$(mac_ops_run_health "${TC_AGENTS}")
    assert_output_contains "${out%%$'\n'*}" "com.mac-ops.cleanup is installed but not loaded" "unloaded agent: alert on the first line"
}

test_health_failed_scheduled_run
test_health_stale_agent
test_health_ok
unset -f _mac_ops_agent_loaded
rm -rf -- "${MAC_OPS_HOME}/runs" "${TC_AGENTS}"

# restore --run: a run that moved X/sub and later X restores both
test_run_restore_nested_order() {
    _t5_reset_trash
    rm -rf -- "${MAC_OPS_HOME}/runs"
    local base="${HOME}/b8nest"
    rm -rf -- "${base}"
    mkdir -p "${base}/X/sub"
    print s > "${base}/X/sub/s.txt"
    print o > "${base}/X/other.txt"
    mac_ops_run_start
    local run_id="${MAC_OPS_RUN_ID}"
    mac_ops_trash_move "${base}/X/sub" "test" "mod-a" >/dev/null 2>&1
    mac_ops_trash_move "${base}/X" "test" "mod-a" >/dev/null 2>&1
    mac_ops_run_finish 0 >/dev/null 2>&1
    local out rc=0
    out=$(_tb_zsh "mac_ops_trash_restore_run '${run_id}'" 2>&1) || rc=$?
    assert_eq "${rc}" "0" "restore --run of X/sub then X: exit 0"
    assert_output_contains "${out}" "2 restored, 0 refused" "restore --run of X/sub then X: both restored"
    assert_eq "$(cat "${base}/X/sub/s.txt" 2>/dev/null)/$(cat "${base}/X/other.txt" 2>/dev/null)" "s/o" "restore --run of X/sub then X: tree back in place"
    rm -rf -- "${base}"
}

# Restore when the destination appears between the check and the move: the
# test's mv() plants the destination, then runs the real mv
test_restore_destination_race() {
    _t5_reset_trash
    local base="${HOME}/b9race" out rc
    rm -rf -- "${base}"; mkdir -p "${base}"

    # A file appears at the destination: never overwritten
    print item > "${base}/f.txt"
    mac_ops_trash_move "${base}/f.txt" "test" "mod-a" >/dev/null 2>&1
    mv() { print planted > "${base}/f.txt"; command mv "$@"; }
    rc=0; mac_ops_trash_restore "${base}/f.txt" >/dev/null 2>&1 || rc=$?
    unset -f mv
    assert_eq "${rc}" "1" "restore: file appearing at the destination is refused"
    assert_eq "$(cat "${base}/f.txt")" "planted" "restore: appeared file is not overwritten"
    assert_eq "$(mac_ops_index_read >/dev/null 2>&1; for k in "${(@k)_MAC_OPS_IDX_ORIG}"; do [[ "${_MAC_OPS_IDX_ORIG[$k]}" == "${base}/f.txt" ]] && cat "${_MAC_OPS_IDX_TRASH[$k]}"; done)" "item" "restore: refused item stays in the trash and the index"

    # A directory appears at the destination: the item must not land inside it
    rm -f -- "${base}/f.txt"
    mac_ops_trash_restore "${base}/f.txt" >/dev/null 2>&1
    print item2 > "${base}/g.txt"
    mac_ops_trash_move "${base}/g.txt" "test" "mod-a" >/dev/null 2>&1
    mv() { mkdir -p "${base}/g.txt"; mv() { command mv "$@"; }; command mv "$@"; }
    rc=0; out=$(mac_ops_trash_restore "${base}/g.txt" 2>&1) || rc=$?
    unset -f mv
    assert_eq "${rc}" "1" "restore: directory appearing at the destination is refused"
    assert_eq "$(ls -A "${base}/g.txt" | grep -c .)" "0" "restore: item not left inside the appeared directory"
    assert_output_contains "${out}" "item kept in the trash" "restore: item moved back into the trash"
    assert_eq "$(mac_ops_index_read >/dev/null 2>&1; for k in "${(@k)_MAC_OPS_IDX_ORIG}"; do [[ "${_MAC_OPS_IDX_ORIG[$k]}" == "${base}/g.txt" ]] && cat "${_MAC_OPS_IDX_TRASH[$k]}"; done)" "item2" "restore: moved-back item still restorable from the index"

    # Normal restore of a directory containing a child of its own name
    rmdir "${base}/g.txt"
    mkdir -p "${base}/d/d"; print n > "${base}/d/d/n.txt"
    mac_ops_trash_move "${base}/d" "test" "mod-a" >/dev/null 2>&1
    rc=0; mac_ops_trash_restore "${base}/d" >/dev/null 2>&1 || rc=$?
    assert_eq "${rc}" "0" "restore: directory with a same-name child restores"
    assert_eq "$(cat "${base}/d/d/n.txt" 2>/dev/null)" "n" "restore: same-name child tree intact"
    rm -rf -- "${base}"
}

# bin/mac-ops status (read-only, under ERR_EXIT): alert on the first line
test_status_cli_alert() {
    reset_fixture
    local saved_home="${MAC_OPS_HOME}"
    MAC_OPS_HOME="${FX_OPS}"
    _tc_manifest 600 true 2 1 0 0
    MAC_OPS_HOME="${saved_home}"
    local out rc=0
    out=$(fx_env zsh "${MAC_OPS_ROOT}/bin/mac-ops" status 2>&1) || rc=$?
    assert_eq "${rc}" "0" "status with a failed scheduled run: exit 0"
    assert_output_contains "${out%%$'\n'*}" "[ALERT] last scheduled run" "status: failed scheduled run alerted on the first line"
    assert_output_contains "${out%%$'\n'*}" "FAILED (exit status 2" "status: failed exit status on the first line"
}

test_run_restore_nested_order
test_restore_destination_race
test_status_cli_alert

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
