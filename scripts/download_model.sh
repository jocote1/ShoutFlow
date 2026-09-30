#!/usr/bin/env bash
set -euo pipefail

MODEL="${1:-small}"
MODELS_DIR="${HOME}/.config/shoutflow/models"

mkdir -p "${MODELS_DIR}"

BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

case "${MODEL}" in
    tiny)
        FILE="ggml-tiny.bin"
        ;;
    base)
        FILE="ggml-base.bin"
        ;;
    small)
        FILE="ggml-small.bin"
        ;;
    small.en-q5_1|small-q5)
        FILE="ggml-small.en-q5_1.bin"
        ;;
    medium)
        FILE="ggml-medium.bin"
        ;;
    large-v3)
        FILE="ggml-large-v3.bin"
        ;;
    *)
        echo "Usage: $0 [tiny|base|small|small.en-q5_1|medium|large-v3]"
        exit 1
        ;;
esac

TARGET="${MODELS_DIR}/${FILE}"

if [[ -f "${TARGET}" ]]; then
    echo "✓ Model ${FILE} is already installed at: ${TARGET}"
    exit 0
fi

echo "Downloading Whisper ${MODEL} model to ${TARGET}..."
curl -L --progress-bar "${BASE_URL}/${FILE}" -o "${TARGET}"

echo "✓ Successfully downloaded ${FILE} (${TARGET})"
echo "ShoutFlow is now ready for offline local transcription!"
