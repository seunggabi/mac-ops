#!/bin/zsh
# =============================================================================
# deploy-brew.sh: Deploy latest mac-ops tag to homebrew-tap
# Usage: ./scripts/deploy-brew.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_OPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOMEBREW_REPO="${MAC_OPS_ROOT}/../homebrew-tap"
FORMULA_PATH="${HOMEBREW_REPO}/Formula/mac-ops.rb"
REPO_URL="https://github.com/seunggabi/mac-ops"

# --- Validate homebrew-tap repo exists ---
if [[ ! -d "${HOMEBREW_REPO}/.git" ]]; then
  echo "[ERROR] homebrew-tap repo not found at: ${HOMEBREW_REPO}"
  echo "  git clone https://github.com/seunggabi/homebrew-tap.git ${HOMEBREW_REPO}"
  exit 1
fi

# --- Get latest tag ---
cd "${MAC_OPS_ROOT}"
git fetch --tags
LATEST_TAG=$(git tag -l 'v*' --sort=-v:refname | head -1)

if [[ -z "${LATEST_TAG}" ]]; then
  echo "[ERROR] No version tags found"
  exit 1
fi

echo "[INFO] Latest tag: ${LATEST_TAG}"

# --- Check current Formula version ---
CURRENT_URL=$(grep 'url "' "${FORMULA_PATH}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
if [[ "${CURRENT_URL}" == "${LATEST_TAG}" ]]; then
  echo "[INFO] Formula already at ${LATEST_TAG}. Nothing to do."
  exit 0
fi

echo "[INFO] Updating Formula: ${CURRENT_URL} → ${LATEST_TAG}"

# --- Calculate sha256 ---
TARBALL_URL="${REPO_URL}/archive/refs/tags/${LATEST_TAG}.tar.gz"
echo "[INFO] Downloading tarball: ${TARBALL_URL}"
NEW_SHA256=$(curl -sL "${TARBALL_URL}" | shasum -a 256 | awk '{print $1}')

if [[ -z "${NEW_SHA256}" || ${#NEW_SHA256} -ne 64 ]]; then
  echo "[ERROR] Failed to calculate sha256"
  exit 1
fi

echo "[INFO] sha256: ${NEW_SHA256}"

# --- Update Formula ---
cd "${HOMEBREW_REPO}"
git pull origin main

sed -i '' "s|url \".*\"|url \"${TARBALL_URL}\"|" "${FORMULA_PATH}"
sed -i '' "s|sha256 \".*\"|sha256 \"${NEW_SHA256}\"|" "${FORMULA_PATH}"

# --- Verify ---
echo "[INFO] Updated Formula:"
grep -E '(url|sha256)' "${FORMULA_PATH}"

# --- Commit and push ---
git add Formula/mac-ops.rb
git commit -m "chore: bump formula to ${LATEST_TAG}"
git push origin main

echo "[DONE] homebrew-tap updated to ${LATEST_TAG}"
