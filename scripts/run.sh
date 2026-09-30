#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

if [[ ! -d "build/ShoutFlow.app" ]]; then
    echo "Building ShoutFlow.app first..."
    ./scripts/build_app.sh
fi

echo "🚀 Starting ShoutFlow..."
echo "Tip: Check the menu bar icon (waveform) to configure settings or switch transcription providers."
open "${PROJECT_DIR}/build/ShoutFlow.app"
