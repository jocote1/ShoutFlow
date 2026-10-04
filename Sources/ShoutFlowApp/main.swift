import AppKit
import Foundation
import ShoutFlowCore

let args = CommandLine.arguments

if args.contains("--help") || args.contains("-h") {
    print("""
    ShoutFlow - AI Dictation Tool for macOS

    Usage:
      ShoutFlow [options]

    Options:
      --check-permissions   Check macOS Accessibility & Microphone status
      --version, -v         Display version
      --help, -h            Show this help message

    Hotkeys and controls:
      Hold Fn:              Record while held. Release to transcribe and paste.
      Double-tap Fn:        Start a hands-free recording. Tap again to stop.
                            (Auto-stops after 5 minutes by default.)
      Esc:                  Cancel a recording or an in-progress transcription.
      Menu bar:             Toggle on/off, change engine, launch at login.

    Configuration:
      Config file:          ~/.config/shoutflow/config.json
      Environment/Keys:     ~/.config/shoutflow/.env or ./.env
      Models directory:     ~/.config/shoutflow/models/
    """)
    exit(0)
}

if args.contains("--version") || args.contains("-v") {
    print("ShoutFlow version 1.1.0")
    exit(0)
}

if args.contains("--check-permissions") {
    let access = Permissions.isAccessibilityGranted
    let mic = Permissions.isMicrophoneGranted
    let whisperInstalled = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli")
    let modelInstalled = FileManager.default.fileExists(atPath: ConfigManager.shared.resolvedPath("~/.config/shoutflow/models/ggml-small.bin"))

    print("--- ShoutFlow System Check ---")
    print("Accessibility:            \(access ? "Granted" : "Not granted (System Settings > Privacy & Security > Accessibility)")")
    print("Microphone:               \(mic ? "Granted" : "Not granted (System Settings > Privacy & Security > Microphone)")")
    print("whisper-cli binary:       \(whisperInstalled ? "Found at /opt/homebrew/bin/whisper-cli" : "Not found (run `brew install whisper-cpp`)")")
    print("ggml-small model:         \(modelInstalled ? "Found" : "Missing (run `./scripts/download_model.sh small`)")")
    print("Config Directory:                  \(ConfigManager.configDirectory.path)")
    print("------------------------------")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
