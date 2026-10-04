#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

echo "Building ShoutFlow in Release mode..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/ShoutFlow"
APP_BUNDLE="${PROJECT_DIR}/build/ShoutFlow.app"

echo "Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/ShoutFlow"
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [[ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

# Generate default config and models dir if not already present
mkdir -p "${HOME}/.config/shoutflow/models"
if [[ ! -f "${HOME}/.config/shoutflow/config.json" ]]; then
    cp "${PROJECT_DIR}/Resources/config.example.json" "${HOME}/.config/shoutflow/config.json"
fi

# Detect valid Apple Development identity
SIGN_IDENTITY=$(security find-identity -p codesigning -v | grep "Apple Development" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)

if [[ -n "${SIGN_IDENTITY}" ]]; then
    echo "Signing bundle with Apple Development certificate: ${SIGN_IDENTITY}..."
    codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "Signing with ad-hoc identity & persistent designated requirement..."
    codesign --force --deep --sign - -r='designated => identifier "no.hnhvgs.ShoutFlow"' "${APP_BUNDLE}"
fi

echo "Installing to /Applications/ShoutFlow.app..."
rm -rf "/Applications/ShoutFlow.app"
cp -R "${APP_BUNDLE}" "/Applications/ShoutFlow.app"

echo ""
echo "ShoutFlow.app built and installed to /Applications/ShoutFlow.app"
echo ""
echo "To launch ShoutFlow:"
echo "  open /Applications/ShoutFlow.app"
