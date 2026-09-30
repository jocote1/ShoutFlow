# ShoutFlow

ShoutFlow is an open-source macOS menu bar app for voice dictation, built as an alternative to Wispr Flow.

It lets you hold a hotkey to record audio, transcribes it locally using whisper.cpp (Metal accelerated on Apple Silicon) or via cloud APIs (Groq, OpenAI), optionally cleans up the text with an LLM, and pastes the result directly into whatever app you have open.

## Features

- **Push-to-talk**: Hold your hotkey to record. When you let go, ShoutFlow transcribes your speech and pastes it at your cursor.
- **Hands-free mode**: Double-tap the hotkey to start recording without holding. Press it again to stop. Automatically stops after 5 minutes.
- **Single-hand hotkeys**: Bind to Fn (Globe), Right Option, Mouse Button 4 (back side button), or Mouse Button 5. Mouse clicks are intercepted so browser navigation is not triggered while dictating.
- **Quick cancel**: Triple-tap your hotkey or press Escape to abort recording or transcription.
- **Audio feedback**: Optional system sounds on start, stop, and cancel.
- **Transcription options**:
  - Local whisper.cpp for private, offline transcription with Metal GPU acceleration.
  - Groq Whisper API for low-latency cloud transcription.
  - OpenAI Whisper API (gpt-transcribe / whisper-1).
  - Priority fallback mode: tries local whisper.cpp first, falls back to Groq if missing or empty, and falls back to OpenAI if needed.
- **Text cleanup**: Optional LLM pass to remove filler words ("um", "uh", "like") and fix capitalization and punctuation. Automatically skipped for short phrases (under 4 words) or speech without fillers to save tokens and avoid delay.
- **Text insertion**: Pastes via simulated Cmd+V or types out keystrokes. Keeps the transcript on your clipboard, with an option to restore your previous clipboard content.
- **HUD pill**: A small floating overlay showing recording state and audio levels while you speak.
- **Settings**: Native macOS preferences window (`Cmd+,`) to change hotkeys, manage local models, set API keys, and test microphones.

## Installation

### Pre-built App
Download the latest `ShoutFlow-v1.1.0-macOS.zip` from the [Releases](https://github.com/jocote1/ShoutFlow/releases) page, unzip it, and drag `ShoutFlow.app` into `/Applications`.

### Build from Source
Requirements: macOS 13.0+, Xcode command line tools, and Swift 5.9+.

```bash
# Clone the repository
git clone https://github.com/jocote1/ShoutFlow.git
cd ShoutFlow

# Install whisper-cpp for local models (optional if using cloud APIs)
brew install whisper-cpp

# Download a local Whisper model (e.g. small or small.en-q5_1)
./scripts/download_model.sh small.en-q5_1

# Build and install to /Applications
./scripts/build_app.sh
```

## Permissions

On first launch, macOS will request:
1. **Microphone**: Needed to capture dictation audio.
2. **Accessibility**: Needed to register global hotkey events and paste text into active applications.
3. **Input Monitoring**: Used to detect the Fn key state and listen for Escape.

You can verify your permissions anytime with:
```bash
/Applications/ShoutFlow.app/Contents/MacOS/ShoutFlow --check-permissions
```

## Usage

| Action | Input | Behavior |
| :--- | :--- | :--- |
| Hold to talk | Hold hotkey | Records while held. Releasing starts transcription and pastes text. |
| Hands-free | Double-tap hotkey | Starts continuous recording. Tap once more to stop and paste. |
| Cancel | Triple-tap hotkey or press Esc | Discards audio and cancels in-flight transcription. |
| Settings | Click menu bar icon → Settings (or `Cmd+,`) | Configure hotkey, STT provider, LLM, and download models. |

## Configuration

Settings are saved in `~/.config/shoutflow/config.json`. API keys are stored locally in `~/.config/shoutflow/.env`:

```env
GROQ_API_KEY=gsk_...
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
```

If you use local whisper.cpp exclusively, no API keys are required.

## License

MIT
