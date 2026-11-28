# lib/utils/security-keywords.zsh
# Security software keyword list shared by every module: a path or executable
# containing one of these (case-insensitive) is never moved or signalled.
# zsh-only parameter flags and nested expansions; false positives in bash mode
# shellcheck disable=SC2296,SC2066,SC2299

# --- Security software is never touched or signalled (case-insensitive substrings) ---
MAC_OPS_SECURITY_KEYWORDS=(
  fortinet forticlient ahnlab astx jiran jkok pnpsecure pcassist wizvera
  delfino veraport iniline crossex initech inisafe nprotect raon touchen
)

# -----------------------------------------------------------------------------
# Return 0 if the path contains a security software keyword
# Usage: _mac_ops_fc_is_security_path <path>
# -----------------------------------------------------------------------------
_mac_ops_fc_is_security_path() {
  local lower_path="${1:l}"
  local keyword=""

  for keyword in "${MAC_OPS_SECURITY_KEYWORDS[@]}"; do
    if [[ "${lower_path}" == *"${keyword}"* ]]; then
      return 0
    fi
  done
  return 1
}
