#!/usr/bin/env bash
set -euo pipefail

# Recall — Automated Release Packaging Script
# Builds Release binary, applies ad-hoc signature, generates DMG & ZIP, computes SHA256 checksums.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
RELEASE_DIR="${BUILD_DIR}/Release"
DIST_DIR="${ROOT_DIR}/dist"

VERSION="0.1.0"
APP_NAME="Recall"
ZIP_NAME="${APP_NAME}-v${VERSION}-macos-arm64.zip"
DMG_NAME="${APP_NAME}-v${VERSION}-macos-arm64.dmg"

echo "=== 1. Building ${APP_NAME} in Release mode ==="
cd "${ROOT_DIR}"
xcodebuild \
  -project Recall.xcodeproj \
  -scheme Recall \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "${APP_PATH}" ]; then
  echo "Error: ${APP_PATH} not found!"
  exit 1
fi

echo "=== 2. Applying Apple Silicon ad-hoc code signature ==="
# Strip any macOS Finder metadata / resource forks so codesign does not reject with "detritus not allowed"
xattr -cr "${APP_PATH}"
# Ad-hoc code signing is crucial for ARM64 macOS binaries to execute without Gatekeeper "damaged" corruption error
codesign --force --deep --sign - "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"
echo "Ad-hoc code signing verified."

echo "=== 3. Packaging distribution assets ==="
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# Package ZIP
echo "Creating ${ZIP_NAME}..."
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${DIST_DIR}/${ZIP_NAME}"

# Package DMG with /Applications symlink
echo "Creating ${DMG_NAME}..."
DMG_STAGE="${BUILD_DIR}/dmg_stage"
rm -rf "${DMG_STAGE}"
mkdir -p "${DMG_STAGE}"
cp -R "${APP_PATH}" "${DMG_STAGE}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGE}/Applications"

hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGE}" \
  -ov \
  -format UDZO \
  "${DIST_DIR}/${DMG_NAME}"

rm -rf "${DMG_STAGE}"

# Compute SHA256 Checksums
echo "Computing SHA256 checksums..."
cd "${DIST_DIR}"
shasum -a 256 "${ZIP_NAME}" "${DMG_NAME}" > checksums.txt

echo "=== Distribution Ready in ${DIST_DIR} ==="
ls -lh "${DIST_DIR}"
cat "${DIST_DIR}/checksums.txt"
