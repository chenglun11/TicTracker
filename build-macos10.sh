#!/bin/bash
set -euo pipefail

APP_NAME="TicTracker"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

ARM64_DIR=".build/arm64-apple-macosx/release"
X86_DIR=".build/x86_64-apple-macosx/release"

echo "==> Building ${APP_NAME} (release, arm64, macOS 10.15)..."
MACOSX_DEPLOYMENT_TARGET=10.15 swift build -c release --triple arm64-apple-macosx

echo "==> Building ${APP_NAME} (release, x86_64, macOS 10.15)..."
MACOSX_DEPLOYMENT_TARGET=10.15 swift build -c release --triple x86_64-apple-macosx

echo "==> Creating universal binary with lipo..."
lipo -create \
    "${ARM64_DIR}/${APP_NAME}" \
    "${X86_DIR}/${APP_NAME}" \
    -output "/tmp/${APP_NAME}-universal"

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"

cp "/tmp/${APP_NAME}-universal" "${MACOS_DIR}/${APP_NAME}"
rm "/tmp/${APP_NAME}-universal"
cp Info.plist "${CONTENTS_DIR}/"

mkdir -p "${CONTENTS_DIR}/Resources"
cp AppIcon.icns "${CONTENTS_DIR}/Resources/"

echo "==> Signing (ad-hoc)..."
codesign --force --sign - --entitlements "${APP_NAME}.entitlements" "${APP_BUNDLE}"

echo "==> Verifying architecture..."
file "${MACOS_DIR}/${APP_NAME}"

echo "==> Done!"
echo "    ${APP_BUNDLE} is ready."
echo "    Run: open ${APP_BUNDLE}"
