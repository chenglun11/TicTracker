#!/bin/bash
set -euo pipefail

APP_NAME="TicTracker"
BUILD_DIR=".build/arm64-apple-macosx/release"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

echo "==> Building ${APP_NAME} (release)..."
swift build -c release

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"

cp "${BUILD_DIR}/${APP_NAME}" "${MACOS_DIR}/"
cp Info.plist "${CONTENTS_DIR}/"

mkdir -p "${CONTENTS_DIR}/Resources"
cp AppIcon.icns "${CONTENTS_DIR}/Resources/"

echo "==> Signing (ad-hoc)..."
codesign --force --sign - --entitlements "${APP_NAME}.entitlements" "${APP_BUNDLE}"

echo "==> Done!"
echo "    ${APP_BUNDLE} is ready."
echo "    Run: open ${APP_BUNDLE}"
