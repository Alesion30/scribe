#!/usr/bin/env bash
# Generate Japanese audio fixtures for scribe regression tests.
#
# Uses macOS `say` (Kyoko voice) to synthesize each phrase directly as
# 16 kHz mono 16-bit WAV — the format scribe's transcription pipeline
# expects. Output files live in Tests/scribeTests/Fixtures/.
#
# Re-run this whenever you want to regenerate fixtures. The committed WAVs
# are the source of truth for tests; regeneration may produce slightly
# different byte sequences depending on macOS version.

set -euo pipefail

cd "$(dirname "$0")/.."

FIXTURE_DIR="Tests/scribeTests/Fixtures"
VOICE="Kyoko"

mkdir -p "$FIXTURE_DIR"

generate() {
    local name="$1"
    local text="$2"
    local wav="$FIXTURE_DIR/${name}.wav"

    echo "[generate] $name -> \"$text\""
    say -v "$VOICE" --file-format=WAVE --data-format=LEI16@16000 -o "$wav" "$text"
}

generate "sample_weather_ja"  "今日はとても良い天気ですね。"
generate "sample_meeting_ja"  "次の会議は明日の午後三時から始まります。"
generate "sample_thanks_ja"   "本日はお越しいただき、ありがとうございます。"

echo
echo "Fixtures written to $FIXTURE_DIR/"
ls -la "$FIXTURE_DIR"/*.wav
