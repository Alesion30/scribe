#!/usr/bin/env bash
# One-shot smoke test for scribe.
#
# Builds scribe and runs the transcribe subcommand against a Japanese fixture,
# then checks the output for an expected keyword. Exits non-zero on failure.

set -euo pipefail

cd "$(dirname "$0")/.."

FIXTURE="Tests/scribeTests/Fixtures/sample_weather_ja.wav"
KEYWORD="天気"
MODEL="${SCRIBE_TEST_MODEL:-large-v3-turbo}"

usage() {
    cat <<'EOF'
Usage: scripts/smoke.sh [-f FIXTURE] [-k KEYWORD] [-m MODEL]

Options:
  -f  Path to a WAV fixture (default: Tests/scribeTests/Fixtures/sample_weather_ja.wav)
  -k  Expected keyword to grep for in the transcript (default: 天気)
  -m  Whisper model name (default: large-v3-turbo, also via SCRIBE_TEST_MODEL)
  -h  Show this help.
EOF
}

while getopts "f:k:m:h" opt; do
    case "$opt" in
        f) FIXTURE="$OPTARG" ;;
        k) KEYWORD="$OPTARG" ;;
        m) MODEL="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ ! -f "$FIXTURE" ]]; then
    echo "[smoke] fixture not found: $FIXTURE" >&2
    echo "[smoke] run scripts/generate-fixtures.sh first" >&2
    exit 1
fi

echo "[smoke] building scribe (release)..."
swift build -c release >/dev/null

BIN=".build/release/scribe"

echo "[smoke] transcribing $FIXTURE (model=$MODEL)..."
OUTPUT=$("$BIN" transcribe "$FIXTURE" -m "$MODEL" -l ja)

echo "[smoke] output: $OUTPUT"

if [[ "$OUTPUT" == *"$KEYWORD"* ]]; then
    echo "[smoke] PASS — found '$KEYWORD'"
    exit 0
else
    echo "[smoke] FAIL — '$KEYWORD' not in output" >&2
    exit 1
fi
