# ShoutFlow 🎙️

A lightweight, private, system-wide AI dictation tool for macOS — inspired by Wispr Flow.

ShoutFlow runs quietly in the background as a menu bar app. It provides instant hold-to-talk dictation, hands-free sessions, real-time waveform visualization in a floating HUD pill, transcription via local `whisper.cpp` (Metal GPU accelerated) or cloud APIs (Groq, OpenAI Whisper), intelligent LLM polishing, and automatic text insertion at your cursor position in any macOS application.

---

## ✨ Features

- **Global Hold-to-Talk Hotkey (`fn`)**: Hold the `fn` key to talk. Release to automatically transcribe, clean up, and insert text at the cursor position.
- **Double-Tap Hands-Free Session**: Double-tap `fn` to enter a hands-free recording session without holding any key. Tap once more to stop and paste.
- **5-Minute Safety Limit**: Hands-free sessions automatically stop after 5 minutes so forgotten recordings never run indefinitely.
- **Passive `Esc` Cancellation**: Press `Esc` anytime to cancel an active recording or abort an in-flight transcription. Esc is monitored passively so it still reaches your active application (e.g. Vim, browser, modals).
- **Offline & Private (whisper.cpp)**: Fast local transcription powered by `whisper.cpp` with Apple Silicon Metal GPU acceleration (`arm64`). No internet required.
- **Cloud Whisper API Support**: Toggle between local whisper.cpp, Groq Whisper (ultra-fast <300ms), or OpenAI Whisper (`gpt-4o-transcribe` / `whisper-1`) with a config flag or menu bar toggle.
- **AI Transcript Polishing**: Pipes raw transcripts through an LLM to eliminate filler words (*"um"*, *"uh"*, *"like"*), correct punctuation, and match casing to natural dictation style.
- **Direct Cursor Insertion**: Pastes text directly at the cursor using simulated `Cmd+V` (or keystrokes). Leaves the text on your clipboard so you can paste it again, with a config flag to restore your previous clipboard instead.
- **Dynamic Floating Pill HUD**: A sleek, dark glassmorphism floating pill that displays live audio waveforms, active mode, elapsed countdown, and transcription status.
- **Menu Bar Controls**: Toggle ShoutFlow on/off, switch engines, configure settings, download models, and enable Launch at Login.
- **No Accounts, No Telemetry**: Zero analytics, zero accounts, pure local control.

---

## 🔒 Permissions & Setup (Important)

macOS requires specific system permissions for global hotkeys, audio recording, and pasting:

### 1. Accessibility (`AXIsProcessTrusted`)
- **Why**: Required to simulate `Cmd+V` for pasting transcribed text and to register global hotkey taps.
- **How to Grant**:
  1. Open **System Settings** → **Privacy & Security** → **Accessibility**.
  2. Click the **`+`** button and select **ShoutFlow** (located in `/Applications` or your `build/` folder).
  3. Ensure the toggle switch next to ShoutFlow is **ON** (blue).
  > *Note: If running ShoutFlow from Terminal during development, grant Accessibility to **Terminal** or **iTerm2**.*

### 2. Input Monitoring
- **Why**: Allows ShoutFlow to detect the `fn` key state and passively monitor the `Esc` key without intercepting keystrokes intended for other apps.
- **How to Grant**:
  1. Open **System Settings** → **Privacy & Security** → **Input Monitoring**.
  2. Add **ShoutFlow** (or your Terminal emulator if developing).
  3. Ensure the toggle is **ON**.

### 3. Microphone Access
- **Why**: Required to capture your voice from the microphone.
- **How to Grant**:
  1. When prompted on first launch, click **Allow**.
  2. Or open **System Settings** → **Privacy & Security** → **Microphone** and toggle ShoutFlow **ON**.

### Permission Check Command
You can test your permission status anytime from your terminal:
```bash
./build/ShoutFlow.app/Contents/MacOS/ShoutFlow --check-permissions
```
Sample output:
```
--- ShoutFlow System Check ---
Accessibility (Input & CGEvent):  ✓ Granted
Microphone Permission:             ✓ Granted
Local whisper-cli Binary:         ✓ Found at /opt/homebrew/bin/whisper-cli
Local Whisper ggml-small Model:    ✓ Found
Config Directory:                  ~/.config/shoutflow
------------------------------
```

---

## 🚀 Quick Start

### 1. Prerequisites
Install `whisper.cpp` via Homebrew for local transcription:
```bash
brew install whisper-cpp
```

### 2. Download Whisper Model
Download the recommended `small` (or `medium`) Whisper model:
```bash
./scripts/download_model.sh small
```
Models are stored in `~/.config/shoutflow/models/`.

### 3. Build & Run
Build the native macOS application bundle:
```bash
./scripts/build_app.sh
```
This produces `build/ShoutFlow.app`.

To launch:
```bash
open build/ShoutFlow.app
```
Or copy to your Applications folder:
```bash
cp -R build/ShoutFlow.app /Applications/
```

---

## ⌨️ How to Use

| Action | Gesture | Description |
| :--- | :--- | :--- |
| **Hold-to-Talk** | Hold `fn` key | Record microphone while held. Release to transcribe, clean up, and insert at cursor. |
| **Hands-Free Session** | Double-tap `fn` | Starts continuous recording without holding. Pill displays elapsed timer. Tap `fn` once more to stop and paste. |
| **Auto-Stop** | Automatic (5 min) | Hands-free sessions automatically stop after 5 minutes of continuous recording. |
| **Cancel** | Press `Esc` | Immediately aborts recording or ongoing transcription and discards audio. Passively passes `Esc` to your active app. |
| **Menu Bar** | Click menu bar icon | Toggle app on/off, switch between Local/Groq/OpenAI, open settings, or toggle launch at login. |

---

## ⚙️ Configuration

ShoutFlow creates and reads settings from:
- **Config file**: `~/.config/shoutflow/config.json`
- **Environment variables**: `~/.config/shoutflow/.env` (or project root `.env`)

### `config.json` Reference

```json
{
  "hotkey": {
    "type": "fn",
    "doubleTapThresholdMs": 350
  },
  "handsFree": {
    "autoStopTimeoutSeconds": 300
  },
  "transcription": {
    "provider": "local",
    "localWhisperBinary": "/opt/homebrew/bin/whisper-cli",
    "localModelPath": "~/.config/shoutflow/models/ggml-small.bin",
    "language": "auto",
    "groqModel": "whisper-large-v3-turbo",
    "openaiModel": "gpt-4o-transcribe"
  },
  "llm": {
    "enabled": true,
    "provider": "groq",
    "model": "llama-3.3-70b-versatile",
    "systemPrompt": "You are an expert dictation assistant.\nTake the raw speech transcript and output a refined, natural text:\n1. Remove verbal fillers and hesitation sounds (such as \"um\", \"uh\", \"like\", \"you know\", \"er\", \"ah\").\n2. Correct punctuation, capitalization, contractions, and sentence boundaries.\n3. Format numbers, dates, currency, and bulleted lists when appropriate.\n4. Match casing and style to smooth dictation.\n5. Strictly preserve the original meaning, tone, intent, and terminology.\n6. Output ONLY the polished dictation text without any preamble, explanation, or quotes."
  },
  "insertion": {
    "method": "paste",
    "restoreClipboard": false,
    "pasteDelayMs": 50
  },
  "ui": {
    "showFloatingPill": true,
    "pillPosition": "bottom"
  }
}
```

### Configuration Options

| Setting | Values | Default | Description |
| :--- | :--- | :--- | :--- |
| `hotkey.type` | `"fn"`, `"rightCommand"`, `"rightOption"` | `"fn"` | Global modifier hotkey for dictation. |
| `hotkey.doubleTapThresholdMs` | Integer (ms) | `350` | Maximum interval between taps to trigger hands-free mode. |
| `handsFree.autoStopTimeoutSeconds` | Integer (seconds) | `300` | Auto-stop safety timeout for hands-free mode (5 min). |
| `transcription.provider` | `"local"`, `"groq"`, `"openai"` | `"local"` | Speech-to-text engine. |
| `transcription.localModelPath` | File path | `~/.config/shoutflow/models/ggml-small.bin` | Path to whisper.cpp GGML model file. |
| `transcription.openaiModel` | Model string | `"gpt-4o-transcribe"` | OpenAI transcription model. |
| `transcription.language` | `"auto"`, `"en"`, etc. | `"auto"` | Audio spoken language. |
| `llm.enabled` | `true`, `false` | `true` | Pipe raw speech through LLM for filler removal and punctuation. |
| `llm.provider` | `"groq"`, `"openai"`, `"anthropic"` | `"groq"` | LLM provider for cleanup. |
| `llm.model` | Model string | `"llama-3.3-70b-versatile"` | LLM model identifier. |
| `insertion.restoreClipboard` | `true`, `false` | `false` | If `false`, leaves transcript on clipboard so you can paste again. If `true`, restores previous clipboard. |
| `ui.pillPosition` | `"bottom"`, `"top"` | `"bottom"` | Position of the floating pill HUD on screen. |

---

## 🔑 Cloud API Keys (`.env`)

To use Groq or OpenAI for transcription or LLM cleanup, add your keys to `~/.config/shoutflow/.env`:

```env
# Groq (Recommended for lightning-fast sub-second transcription and LLM cleanup)
GROQ_API_KEY=gsk_...

# OpenAI (For OpenAI Whisper and GPT cleanup)
OPENAI_API_KEY=sk-...

# Anthropic (Optional)
ANTHROPIC_API_KEY=sk-ant-...
```

*When no API keys are provided and `transcription.provider` is set to `"local"`, ShoutFlow functions 100% offline using `whisper.cpp`.*

---

## 🧪 Testing

Run the test suite with `swift test`:
```bash
swift test
```
The test suite validates:
- Configuration parsing & default values
- 5-minute hands-free auto-stop parameters
- Path expansion (`~` to home directory)
- Real audio recording transcription with `whisper.cpp` (Metal GPU)
- Clipboard insertion and restore behavior

---

## 🛠️ Project Architecture

```
ShoutFlow/
├── Package.swift                    # Swift Package Manager manifest
├── Sources/
│   ├── ShoutFlowCore/               # Core library
│   │   ├── Core/
│   │   │   ├── Config.swift         # JSON & .env settings manager
│   │   │   └── HotKeyMonitor.swift  # CGEventTap & passive Esc monitor
│   │   ├── Audio/
│   │   │   └── AudioRecorder.swift  # 16kHz mono WAV recording & audio metering
│   │   ├── Transcription/
│   │   │   └── TranscriptionService.swift # Local whisper.cpp, Groq, OpenAI
│   │   ├── LLM/
│   │   │   └── LLMService.swift     # Filler removal, punctuation, casing
│   │   ├── Insertion/
│   │   │   └── TextInserter.swift   # Cursor paste & clipboard manager
│   │   ├── UI/
│   │   │   ├── FloatingPillWindow.swift # Floating glass HUD & live waveform
│   │   │   └── StatusBarMenu.swift  # Menu bar icon, toggles, settings
│   │   ├── App/
│   │   │   └── AppDelegate.swift    # Application coordinator
│   │   └── Utils/
│   │       ├── Permissions.swift    # macOS Accessibility & Mic verification
│   │       └── LaunchAtLogin.swift  # SMAppService & LaunchAgent manager
│   └── ShoutFlowApp/
│       └── main.swift               # Application entrypoint & CLI flags
├── Tests/
│   └── ShoutFlowTests/
│       └── ShoutFlowTests.swift     # Unit & integration test suite
├── Resources/
│   ├── Info.plist                   # App bundle settings (LSUIElement = true)
│   ├── config.example.json          # Documented configuration template
│   └── .env.example                 # API key template
└── scripts/
    ├── build_app.sh                 # Builds and signs ShoutFlow.app
    ├── download_model.sh            # Downloads Whisper GGML models
    └── run.sh                       # Quick development runner
```

---

## 📄 License

MIT License. Free to use, modify, and distribute.
