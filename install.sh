#!/usr/bin/env bash
set -euo pipefail

# Recall — 1-Line Installer for macOS
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/main/install.sh | bash

REPO_SLUG="${RECALL_REPO:-miras/recall}"
INSTALL_DIR="/Applications"
APP_NAME="Recall.app"
TARGET_APP="${INSTALL_DIR}/${APP_NAME}"

echo ""
echo "  ● Recall — Local-first Neural Clipboard"
echo "  ────────────────────────────────────────"
echo ""

# 1. Architecture and OS check
OS="$(uname -s)"
ARCH="$(uname -m)"

if [ "$OS" != "Darwin" ]; then
  echo "  Error: Recall is exclusively built for macOS."
  exit 1
fi

if [ "$ARCH" != "arm64" ]; then
  echo "  Error: Recall requires Apple Silicon (M1/M2/M3/M4) for local Neural Engine execution."
  exit 1
fi

# 2. Resolve download URL
echo "  → Finding latest release..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/${REPO_SLUG}/releases/latest" 2>/dev/null | grep '"tag_name":' | head -n 1 | cut -d '"' -f 4 || echo "")

if [ -z "$LATEST_TAG" ]; then
  # Fallback to direct stable tag if GitHub API is rate-limited
  LATEST_TAG="v0.1.0"
fi

ZIP_URL="https://github.com/${REPO_SLUG}/releases/download/${LATEST_TAG}/Recall-${LATEST_TAG}-macos-arm64.zip"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "  → Downloading Recall (${LATEST_TAG})..."
if ! curl -fL --progress-bar "$ZIP_URL" -o "${TMP_DIR}/Recall.zip"; then
  echo ""
  echo "  Could not fetch binary from ${ZIP_URL}."
  echo "  If the release is not yet published on GitHub, you can build from source:"
  echo "    git clone https://github.com/${REPO_SLUG}.git"
  echo "    cd recall && make build"
  exit 1
fi

# 3. Stop running instance if any
if pgrep -x "Recall" > /dev/null 2>&1; then
  echo "  → Closing existing Recall instance..."
  pkill -x "Recall" || true
  sleep 1
fi

# 4. Extract and Install
echo "  → Installing to ${INSTALL_DIR}..."
rm -rf "${TMP_DIR}/extracted"
mkdir -p "${TMP_DIR}/extracted"
unzip -q "${TMP_DIR}/Recall.zip" -d "${TMP_DIR}/extracted"

# Look for Recall.app in extracted folder
EXTRACTED_APP=$(find "${TMP_DIR}/extracted" -maxdepth 2 -name "Recall.app" -type d | head -n 1)

if [ -z "$EXTRACTED_APP" ]; then
  echo "  Error: Could not locate Recall.app inside archive."
  exit 1
fi

rm -rf "${TARGET_APP}"
cp -R "${EXTRACTED_APP}" "${TARGET_APP}"

# 5. Remove quarantine attribute (bypasses Gatekeeper without needing Developer ID)
echo "  → Clearing Gatekeeper quarantine..."
xattr -cr "${TARGET_APP}" 2>/dev/null || true

# Re-apply ad-hoc signature locally to ensure binary integrity
codesign --force --deep --sign - "${TARGET_APP}" > /dev/null 2>&1 || true

echo ""
echo "  ✓ Recall successfully installed to /Applications/Recall.app"
echo ""
echo "  Shortcut: Press ⌥Space anywhere to summon Recall."
echo ""

# Launch if interactive
if [ -t 0 ] || [ -n "${LAUNCH_NOW:-}" ]; then
  open "${TARGET_APP}"
  echo "  → Launched Recall."
fi
