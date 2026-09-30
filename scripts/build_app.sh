#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

echo "🔨 Building ShoutFlow in Release mode..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/ShoutFlow"
APP_BUNDLE="${PROJECT_DIR}/build/ShoutFlow.app"

echo "📦 Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/ShoutFlow"
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Generate default config and models dir if not already present
mkdir -p "${HOME}/.config/shoutflow/models"
if [[ ! -f "${HOME}/.config/shoutflow/config.json" ]]; then
    cp "${PROJECT_DIR}/Resources/config.example.json" "${HOME}/.config/shoutflow/config.json"
fi

echo "🔏 Ad-hoc code signing the application bundle..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo ""
echo "✅ ShoutFlow.app built successfully at: ${APP_BUNDLE}"
echo ""
echo "To install to your Applications folder:"
echo "  cp -R \"${APP_BUNDLE}\" /Applications/"
echo ""
echo "To launch right now:"
echo "  open \"${APP_BUNDLE}\""
