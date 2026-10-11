#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="TokenFuel"
APP_PATH="${SCRIPT_DIR}/${APP_NAME}.app"
CONTENTS_PATH="${APP_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
RESOURCES_PATH="${CONTENTS_PATH}/Resources"

echo "Building ${APP_NAME}..."

# Clean previous build
rm -rf "${APP_PATH}"

# Create app bundle structure
mkdir -p "${MACOS_PATH}"
mkdir -p "${RESOURCES_PATH}"

# Copy Info.plist
cp "${SCRIPT_DIR}/Info.plist" "${CONTENTS_PATH}/"

# Compile Swift
echo "Compiling Swift..."
swiftc -O \
    "${SCRIPT_DIR}/Sources/main.swift" \
    -o "${MACOS_PATH}/${APP_NAME}" \
    -swift-version 5 \
    -framework Cocoa \
    -framework Foundation

# Make executable
chmod +x "${MACOS_PATH}/${APP_NAME}"

# Code sign
echo "Code signing..."
codesign -s - --force --deep "${APP_PATH}" 2>/dev/null || true

echo "Build complete: ${APP_PATH}"
