#!/bin/bash
set -euo pipefail

APP_NAME="TicTracker"
BUILD_DIR=".build/arm64-apple-macosx/release"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Kill running instance only if it's from this project directory
RUNNING_PID=$(pgrep -f "${PROJECT_DIR}/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" || true)
if [ -n "$RUNNING_PID" ]; then
    echo "==> Killing running ${APP_NAME} (PID: ${RUNNING_PID})..."
    kill "$RUNNING_PID" 2>/dev/null || true
    sleep 0.5
fi

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

echo "==> Launching ${APP_NAME}..."
open "${PROJECT_DIR}/${APP_BUNDLE}"

echo "==> Done!"
