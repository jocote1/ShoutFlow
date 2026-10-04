import SwiftUI
import AppKit
import CoreAudio

public struct SettingsView: View {
    @ObservedObject var modelManager = ModelManager.shared

    // Form state initialized from ConfigManager
    @State private var hotkeyType: String
    @State private var doubleTapMs: Double
    @State private var tripleTapToCancel: Bool
    @State private var soundEffectsEnabled: Bool
    @State private var autoStopMinutes: Int
    @State private var insertionMethod: String
    @State private var restoreClipboard: Bool
    @State private var launchAtLogin: Bool

    // Transcription state
    @State private var transcriptionProvider: String
    @State private var spokenLanguage: String
    @State private var groqModel: String
    @State private var openaiModel: String

    // LLM & API Keys state
    @State private var llmEnabled: Bool
    @State private var llmProvider: String
    @State private var llmModel: String
    @State private var bypassShortPhrases: Bool
    @State private var systemPrompt: String
    @State private var groqApiKey: String
    @State private var openaiApiKey: String
    @State private var anthropicApiKey: String

    @State private var showGroqKey: Bool = false
    @State private var showOpenAiKey: Bool = false
    @State private var showAnthropicKey: Bool = false

    // UI Feedback
    @State private var showSaveSuccess: Bool = false
    @State private var isAccessibilityGranted: Bool = Permissions.isAccessibilityGranted
    @State private var isMicrophoneGranted: Bool = Permissions.isMicrophoneGranted
    @State private var isTestRecording: Bool = false

    // Audio Input Devices
    @State private var availableMicrophones: [AudioInputDevice] = []
    @State private var selectedMicrophoneId: AudioDeviceID = 0

    public init() {
        let config = ConfigManager.shared.config
        let env = ConfigManager.shared.env
        let defMicId = AudioDeviceManager.shared.getDefaultInputDeviceID()

        _selectedMicrophoneId = State(initialValue: defMicId)

        _hotkeyType = State(initialValue: config.hotkey.type.lowercased())
        _doubleTapMs = State(initialValue: Double(config.hotkey.doubleTapThresholdMs))
        _tripleTapToCancel = State(initialValue: config.hotkey.tripleTapToCancel)
        _soundEffectsEnabled = State(initialValue: config.ui.soundEffectsEnabled)
        _autoStopMinutes = State(initialValue: max(1, config.handsFree.autoStopTimeoutSeconds / 60))
        _insertionMethod = State(initialValue: config.insertion.method)
        _restoreClipboard = State(initialValue: config.insertion.restoreClipboard)
        _launchAtLogin = State(initialValue: LaunchAtLogin.isEnabled)

        _transcriptionProvider = State(initialValue: config.transcription.provider)
        _spokenLanguage = State(initialValue: config.transcription.language)
        _groqModel = State(initialValue: config.transcription.groqModel)
        _openaiModel = State(initialValue: config.transcription.openaiModel)

        _llmEnabled = State(initialValue: config.llm.enabled)
        _llmProvider = State(initialValue: config.llm.provider)
        _llmModel = State(initialValue: config.llm.model)
        _bypassShortPhrases = State(initialValue: config.llm.bypassShortPhrases)
        _systemPrompt = State(initialValue: config.llm.systemPrompt)

        _groqApiKey = State(initialValue: env["GROQ_API_KEY"] ?? "")
        _openaiApiKey = State(initialValue: env["OPENAI_API_KEY"] ?? "")
        _anthropicApiKey = State(initialValue: env["ANTHROPIC_API_KEY"] ?? "")
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Text("General") }

            transcriptionTab
                .tabItem { Text("Transcription") }

            llmTab
                .tabItem { Text("Cleanup and Keys") }

            permissionsTab
                .tabItem { Text("Permissions") }
        }
        .frame(width: 580, height: 490)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .safeAreaInset(edge: .bottom) {
            bottomToolbar
        }
        .onAppear {
            refreshPermissionStatus()
            refreshMicrophoneDevices()
            isTestRecording = AudioRecorder.shared.isRecording
        }
    }

    private func refreshMicrophoneDevices() {
        availableMicrophones = AudioDeviceManager.shared.getInputDevices()
        selectedMicrophoneId = AudioDeviceManager.shared.getDefaultInputDeviceID()
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section(header: Text("Hotkey").bold()) {
                Picker("Hold-to-talk key:", selection: $hotkeyType) {
                    Text("Fn (Globe)").tag("fn")
                    Text("Right Option").tag("rightoption")
                    Text("Right Command").tag("rightcommand")
                    Text("Right Control").tag("rightcontrol")
                    Text("Control + Space").tag("ctrlspace")
                    Text("Option + Space").tag("optspace")
                    Text("Mouse Button 4 (back)").tag("mouse4")
                    Text("Mouse Button 5 (forward)").tag("mouse5")
                }
                .pickerStyle(.menu)

                Toggle("Triple-tap the hotkey to cancel", isOn: $tripleTapToCancel)
                Text("Tap the hotkey three times quickly to cancel a recording or transcription without reaching for Esc.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Play sounds", isOn: $soundEffectsEnabled)
                Text("Plays a short system sound when recording starts (Tink), stops (Pop) and is canceled (Basso).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Double-tap interval:")
                        Spacer()
                        Text("\(Int(doubleTapMs)) ms")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $doubleTapMs, in: 200...600, step: 25)
                    Text("Maximum time between two taps to start a hands-free session.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Picker("Hands-free auto-stop:", selection: $autoStopMinutes) {
                    Text("1 minute").tag(1)
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                }
                .pickerStyle(.menu)
                Text("Stops a hands-free recording automatically so it cannot run forever if you forget it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Microphone").bold()) {
                if availableMicrophones.isEmpty {
                    Text("No microphone inputs detected.")
                        .foregroundColor(.secondary)
                } else {
                    Picker("Input device:", selection: $selectedMicrophoneId) {
                        ForEach(availableMicrophones, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedMicrophoneId) { newId in
                        AudioDeviceManager.shared.setDefaultInputDevice(id: newId)
                    }
                }
                Text("This changes the system default input device. The built-in microphone avoids the delay Bluetooth headsets add.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Test Dictation").bold()) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Test without a hotkey").font(.subheadline).bold()
                        Text("Record a phrase and paste the result to check that everything works.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(isTestRecording ? "Stop and Paste" : "Start Test") {
                        AppDelegate.shared?.toggleManualDictation()
                        isTestRecording = AudioRecorder.shared.isRecording
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section(header: Text("Text Insertion").bold()) {
                Picker("Method:", selection: $insertionMethod) {
                    Text("Paste with Cmd+V (faster, more reliable)").tag("paste")
                    Text("Type each character").tag("keystrokes")
                }
                .pickerStyle(.menu)

                Toggle("Restore the previous clipboard after pasting", isOn: $restoreClipboard)
                Text(restoreClipboard ? "Your earlier clipboard contents come back about 350 ms after the paste." : "The transcript stays on the clipboard so you can paste it again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("System").bold()) {
                Toggle("Launch ShoutFlow at login", isOn: $launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Transcription Tab

    private var transcriptionTab: some View {
        Form {
            Section(header: Text("Speech Recognition Engine").bold()) {
                Picker("Provider:", selection: $transcriptionProvider) {
                    Text("Priority Fallback").tag("priority")
                    Text("Local Whisper").tag("local")
                    Text("Groq API").tag("groq")
                    Text("OpenAI API").tag("openai")
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Spoken Language:")
                    Spacer()
                    TextField("auto", text: $spokenLanguage)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Use 'auto' for automatic language detection, or codes like 'en', 'no', 'es', 'de'.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if transcriptionProvider == "priority" {
                Section(header: Text("Fallback Order").bold()) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Local Whisper (whisper.cpp)").bold()
                        Text("Runs offline on your Mac at no cost.")
                            .font(.caption).foregroundColor(.secondary)
                        Text("2. Groq (whisper-large-v3-turbo)").bold()
                        Text("Used if the local model is missing, fails, or returns nothing.")
                            .font(.caption).foregroundColor(.secondary)
                        Text("3. OpenAI (gpt-4o-transcribe)").bold()
                        Text("Last resort if Groq has no API key or fails.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            if transcriptionProvider == "local" || transcriptionProvider == "priority" {
                Section(header: Text("Local Whisper Models").bold()) {
                    let binaryFound = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli")
                        || FileManager.default.fileExists(atPath: "/usr/local/bin/whisper-cli")
                    HStack {
                        Text(binaryFound ? "whisper-cli: installed" : "whisper-cli: not found. Install it with `brew install whisper-cpp`.")
                            .font(.subheadline)
                            .foregroundColor(binaryFound ? .secondary : .orange)
                    }

                    ForEach(ModelManager.availableModels) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(model.name).bold()
                                    if modelManager.isModelActive(model) {
                                        Text("Active")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.2))
                                            .foregroundColor(.blue)
                                            .cornerRadius(4)
                                    }
                                }
                                Text("\(model.filename), \(model.diskSizeString ?? model.estimatedSize)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if model.isInstalled {
                                HStack(spacing: 8) {
                                    Text("Installed")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if !modelManager.isModelActive(model) {
                                        Button("Use Model") {
                                            modelManager.setActiveModel(model)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            } else {
                                if modelManager.currentlyDownloadingModelId == model.id {
                                    HStack(spacing: 8) {
                                        ProgressView(value: modelManager.downloadProgress)
                                            .frame(width: 80)
                                        Text("\(Int(modelManager.downloadProgress * 100))%")
                                            .font(.caption)
                                            .monospacedDigit()
                                        Button("Cancel") {
                                            modelManager.cancelDownload()
                                        }
                                        .controlSize(.small)
                                    }
                                } else {
                                    Button("Download") {
                                        modelManager.downloadModel(model)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            if transcriptionProvider == "groq" || transcriptionProvider == "priority" {
                Section(header: Text("Groq Transcription").bold()) {
                    TextField("Model:", text: $groqModel)
                        .textFieldStyle(.roundedBorder)
                    Text("Default: whisper-large-v3-turbo.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if transcriptionProvider == "openai" || transcriptionProvider == "priority" {
                Section(header: Text("OpenAI Transcription").bold()) {
                    TextField("Model:", text: $openaiModel)
                        .textFieldStyle(.roundedBorder)
                    Text("Default: gpt-4o-transcribe. whisper-1 also works.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - LLM & API Keys Tab

    private func apiKeyRow(label: String, placeholder: String, text: Binding<String>, isRevealed: Binding<Bool>) -> some View {
        HStack {
            Text("\(label):")
                .frame(width: 80, alignment: .leading)
            if isRevealed.wrappedValue {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
            } else {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
            }
            Button(isRevealed.wrappedValue ? "Hide" : "Show") {
                isRevealed.wrappedValue.toggle()
            }
            .buttonStyle(.borderless)
            .frame(width: 36)
        }
    }

    private static let defaultLLMModels: [String: String] = [
        "groq": "llama-3.1-8b-instant",
        "openai": "gpt-4o-mini",
        "anthropic": "claude-3-5-haiku-20241022"
    ]

    private var llmTab: some View {
        Form {
            Section(header: Text("Transcript Cleanup").bold()) {
                Toggle("Clean up transcripts with an LLM (fillers, punctuation, casing)", isOn: $llmEnabled)

                if llmEnabled {
                    Toggle("Skip the LLM for short or clean transcripts", isOn: $bypassShortPhrases)
                    Text("Skips cleanup when the transcript is under 4 words or has no filler words. Saves API cost and latency.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Provider:", selection: $llmProvider) {
                        Text("Groq").tag("groq")
                        Text("OpenAI").tag("openai")
                        Text("Anthropic").tag("anthropic")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: llmProvider) { newProvider in
                        let knownDefaults = Set(SettingsView.defaultLLMModels.values)
                        let current = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        if current.isEmpty || knownDefaults.contains(current),
                           let replacement = SettingsView.defaultLLMModels[newProvider] {
                            llmModel = replacement
                        }
                    }

                    TextField("Model:", text: $llmModel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section(header: Text("API Keys").bold()) {
                VStack(alignment: .leading, spacing: 6) {
                    apiKeyRow(label: "Groq", placeholder: "gsk_...", text: $groqApiKey, isRevealed: $showGroqKey)
                    apiKeyRow(label: "OpenAI", placeholder: "sk-...", text: $openaiApiKey, isRevealed: $showOpenAiKey)
                    apiKeyRow(label: "Anthropic", placeholder: "sk-ant-...", text: $anthropicApiKey, isRevealed: $showAnthropicKey)
                }
                Text("Keys are stored locally in ~/.config/shoutflow/.env and are only sent to the provider you select.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if llmEnabled {
                Section(header: Text("Dictation Cleanup Prompt").bold()) {
                    TextEditor(text: $systemPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 70)
                        .cornerRadius(6)

                    Button("Reset to Recommended Prompt") {
                        systemPrompt = ShoutFlowConfig.LLMConfig().systemPrompt
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Permissions Tab

    private var permissionsTab: some View {
        Form {
            Section(header: Text("Permissions").bold()) {
                permissionRow(
                    title: "Accessibility",
                    detail: "Required for global hotkeys and pasting text into other apps.",
                    isGranted: isAccessibilityGranted,
                    buttonTitle: "Open Settings"
                ) {
                    Permissions.openAccessibilitySettings()
                }

                permissionRow(
                    title: "Microphone",
                    detail: "Required to record your voice.",
                    isGranted: isMicrophoneGranted,
                    buttonTitle: "Grant Access"
                ) {
                    Permissions.requestMicrophone { _ in
                        refreshPermissionStatus()
                    }
                }

                HStack {
                    VStack(alignment: .leading) {
                        Text("Input Monitoring").bold()
                        Text("Required to detect the Esc key and modifier-key hotkeys.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") {
                        Permissions.openInputMonitoringSettings()
                    }
                    .controlSize(.small)
                }
            }

            Section {
                Button("Refresh Status") {
                    refreshPermissionStatus()
                }
            }

            Section(header: Text("Troubleshooting").bold()) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("If System Settings shows ShoutFlow as enabled but the app still reports Missing:")
                        .font(.subheadline)
                    Text("1. Open System Settings > Privacy & Security > Accessibility.\n2. Select ShoutFlow and click the minus (-) button to remove it.\n3. Click (+) and add ShoutFlow again from your Applications folder.\n4. Click \"Re-request Accessibility\" below.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Re-request Accessibility") {
                        Permissions.requestAccessibility()
                        refreshPermissionStatus()
                    }
                    .controlSize(.small)

                    Button("Open Log File") {
                        NSWorkspace.shared.open(AppLogger.logFileURL)
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(
        title: String,
        detail: String,
        isGranted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).bold()
                    Text(isGranted ? "Granted" : "Missing")
                        .font(.caption)
                        .foregroundColor(isGranted ? .green : .red)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !isGranted {
                Button(buttonTitle, action: action)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack {
            Button("Open Config Folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ConfigManager.configDirectory.path)
            }
            .buttonStyle(.link)
            .font(.caption)

            Button("View Logs") {
                NSWorkspace.shared.open(AppLogger.logFileURL)
            }
            .buttonStyle(.link)
            .font(.caption)

            Spacer()

            if showSaveSuccess {
                Text("Settings saved")
                    .font(.caption)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }

            Button("Save Changes") {
                saveAllSettings()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Material.bar)
    }

    // MARK: - Actions

    private func refreshPermissionStatus() {
        isAccessibilityGranted = Permissions.isAccessibilityGranted
        isMicrophoneGranted = Permissions.isMicrophoneGranted
    }

    private func saveAllSettings() {
        var cfg = ConfigManager.shared.config

        // General
        cfg.hotkey.type = hotkeyType
        cfg.hotkey.doubleTapThresholdMs = Int(doubleTapMs)
        cfg.hotkey.tripleTapToCancel = tripleTapToCancel
        cfg.ui.soundEffectsEnabled = soundEffectsEnabled
        cfg.handsFree.autoStopTimeoutSeconds = autoStopMinutes * 60
        cfg.insertion.method = insertionMethod
        cfg.insertion.restoreClipboard = restoreClipboard
        LaunchAtLogin.isEnabled = launchAtLogin

        // Transcription
        let trimmedLanguage = spokenLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedGroqModel = groqModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOpenAIModel = openaiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLLMModel = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)

        cfg.transcription.provider = transcriptionProvider
        cfg.transcription.language = trimmedLanguage.isEmpty ? "auto" : trimmedLanguage
        cfg.transcription.groqModel = trimmedGroqModel
        cfg.transcription.openaiModel = trimmedOpenAIModel

        // LLM
        cfg.llm.enabled = llmEnabled
        cfg.llm.provider = llmProvider
        cfg.llm.model = trimmedLLMModel
        cfg.llm.bypassShortPhrases = bypassShortPhrases
        cfg.llm.systemPrompt = systemPrompt

        ConfigManager.shared.saveConfig(cfg)
        AppDelegate.shared?.setupServices()
        AppDelegate.shared?.statusBarMenu.refreshHotkeyTitle()

        // Save API keys to .env (trimmed so pasted keys with stray whitespace still work)
        ConfigManager.shared.setEnvKey("GROQ_API_KEY", value: groqApiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ConfigManager.shared.setEnvKey("OPENAI_API_KEY", value: openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ConfigManager.shared.setEnvKey("ANTHROPIC_API_KEY", value: anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines))

        withAnimation {
            showSaveSuccess = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showSaveSuccess = false
            }
        }
    }
}
