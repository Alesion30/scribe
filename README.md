# scribe

A macOS command-line tool that captures audio from the microphone and/or system audio, then transcribes it locally using [whisper.cpp](https://github.com/ggml-org/whisper.cpp). All processing happens on-device — no data leaves your machine.

## Features

- **Dual audio capture** — Record microphone and system audio simultaneously via ScreenCaptureKit (macOS 15+)
- **Local transcription** — Runs whisper.cpp on-device with Metal GPU acceleration
- **Flexible workflow** — Record and transcribe in one step, or use them separately
- **Language detection** — Automatic language detection or manual hint (ISO 639-1)
- **Model management** — Download, list, and remove whisper models from the CLI

## Requirements

- macOS 15.0 (Sequoia) or later
- Xcode 16+ / Swift 6.0+
- Screen Recording permission (System Settings > Privacy & Security > Screen & System Audio Recording)

## Installation

### Build from Source

```bash
git clone https://github.com/your-username/scribe.git
cd scribe
swift build -c release
```

The binary will be at `.build/release/scribe`. You can copy it to a directory in your `$PATH`:

```bash
cp .build/release/scribe /usr/local/bin/
```

### Download a Model

scribe requires a whisper.cpp compatible model (GGML format). Download one before first use:

```bash
# Recommended for most users (~809 MB, best speed/accuracy balance)
scribe model download large-v3-turbo \
  -u https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

# Lightweight alternative (~142 MB, faster but less accurate)
scribe model download base \
  -u https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

Models are saved to `~/.scribe/models/`.

## Usage

### Record and Transcribe (Default)

```bash
# Record audio, then transcribe when you press Ctrl+C
scribe

# Specify a model and language
scribe -m base -l en

# Save the recording as a WAV file
scribe -w recording.wav

# Write transcript to a file instead of stdout
scribe -o transcript.txt
```

### Record Only

```bash
# Record and save as WAV (no transcription)
scribe record -o meeting.wav

# System audio only (no microphone)
scribe record --no-mic

# Microphone only (no system audio)
scribe record --no-system
```

### Transcribe an Existing File

```bash
# Transcribe a WAV file
scribe transcribe recording.wav

# Specify model and language
scribe transcribe recording.wav -m large-v3-turbo -l ja
```

### Manage Models

```bash
# List downloaded models
scribe model list

# Download a model
scribe model download <name> -u <url>

# Remove a model
scribe model remove <name>
```

### Verbose Output

Add `-v` / `--verbose` to any command for detailed logging to stderr:

```bash
scribe -v -m base
```

## Configuration

scribe uses a layered configuration system. Priority (highest to lowest):

1. CLI flags
2. Config file (`~/.scribe/config.json`)
3. Built-in defaults

### Config File

Create `~/.scribe/config.json` to set persistent defaults:

```json
{
  "model": "large-v3-turbo",
  "language": "auto",
  "recordingDir": "~/.scribe/recordings",
  "noMic": false,
  "noSystem": false
}
```

All fields are optional. A JSON Schema is available at [`schema/config.schema.json`](schema/config.schema.json).

### Environment Variables

| Variable | Description |
|---|---|
| `SCRIBE_HOME` | Override the base directory (default: `~/.scribe`) |

### Directory Structure

```
~/.scribe/
├── config.json        # Configuration file (optional)
├── models/            # Downloaded whisper models
│   └── base.bin
└── recordings/        # Saved audio recordings
    └── 2025-01-15_14-30-00.wav
```

## Permissions

On first run, macOS will prompt for the following permissions:

| Permission | Required For | Where to Enable |
|---|---|---|
| Screen & System Audio Recording | Capturing system audio | System Settings > Privacy & Security > Screen & System Audio Recording |
| Microphone | Capturing microphone input | System Settings > Privacy & Security > Microphone |

Grant access to your terminal application (Terminal, iTerm2, etc.).

## Available Models

| Model | Size | Description |
|---|---|---|
| `tiny` | ~75 MB | Fastest, least accurate |
| `base` | ~142 MB | Good for quick tests |
| `small` | ~466 MB | Balanced |
| `medium` | ~1.5 GB | More accurate |
| `large-v3-turbo` | ~809 MB | Best speed/accuracy tradeoff (default) |
| `large-v3` | ~1.5 GB | Most accurate |

All models are available from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp/tree/main). Use the `ggml-*.bin` files.

## Architecture

scribe is built with:

- **[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)** — macOS framework for audio/screen capture with `captureMicrophone` support (macOS 15+)
- **[whisper.cpp](https://github.com/ggml-org/whisper.cpp)** — C/C++ port of OpenAI's Whisper model, integrated via XCFramework with Metal GPU acceleration
- **[Swift Argument Parser](https://github.com/apple/swift-argument-parser)** — Type-safe CLI argument parsing
- **[Accelerate (vDSP)](https://developer.apple.com/documentation/accelerate/vdsp)** — Hardware-accelerated audio signal processing

## License

MIT

## Acknowledgments

- [OpenAI Whisper](https://github.com/openai/whisper) — Original speech recognition model
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — High-performance C/C++ inference engine
