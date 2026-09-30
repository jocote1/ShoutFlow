import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var modelManager = ModelManager.shared

    // Form state initialized from ConfigManager
    @State private var hotkeyType: String
    @State private var doubleTapMs: Double
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

    public init() {
        let config = ConfigManager.shared.config
        let env = ConfigManager.shared.env

        _hotkeyType = State(initialValue: config.hotkey.type)
        _doubleTapMs = State(initialValue: Double(config.hotkey.doubleTapThresholdMs))
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
        _systemPrompt = State(initialValue: config.llm.systemPrompt)

        _groqApiKey = State(initialValue: env["GROQ_API_KEY"] ?? "")
        _openaiApiKey = State(initialValue: env["OPENAI_API_KEY"] ?? "")
        _anthropicApiKey = State(initialValue: env["ANTHROPIC_API_KEY"] ?? "")
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            transcriptionTab
                .tabItem {
                    Label("Transcription", systemImage: "waveform")
                }

            llmTab
                .tabItem {
                    Label("AI Polish & Keys", systemImage: "sparkles")
                }

            permissionsTab
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
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
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section(header: Text("Hotkey & Dictation Controls").bold()) {
                Picker("Hold-to-Talk Hotkey:", selection: $hotkeyType) {
                    Text("Fn (Globe Key)").tag("fn")
                    Text("Right Command (⌘)").tag("rightcommand")
                    Text("Right Option (⌥)").tag("rightoption")
                    Text("Right Control (⌃)").tag("rightcontrol")
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Double-Tap Interval:")
                        Spacer()
                        Text("\(Int(doubleTapMs)) ms")
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $doubleTapMs, in: 200...600, step: 25)
                    Text("Maximum delay between two taps to start a hands-free session.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Picker("Hands-Free Auto-Stop:", selection: $autoStopMinutes) {
                    Text("1 minute").tag(1)
                    Text("3 minutes").tag(3)
                    Text("5 minutes (Recommended)").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                }
                .pickerStyle(.menu)
                Text("Safety limit to prevent endless recording if forgotten.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Text Insertion & Clipboard").bold()) {
                Picker("Insertion Method:", selection: $insertionMethod) {
                    Text("Paste via Cmd+V (Fastest & Reliable)").tag("paste")
                    Text("Simulate Keystrokes (Type Character by Character)").tag("keystrokes")
                }
                .pickerStyle(.menu)

                Toggle("Restore original clipboard after paste", isOn: $restoreClipboard)
                Text(restoreClipboard ? "Restores your prior clipboard content ~350ms after pasting." : "Leaves transcript on clipboard so you can paste it again anywhere.")
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
                    Text("Local Whisper (whisper.cpp - Offline & Private)").tag("local")
                    Text("Groq Whisper API (Ultra-Fast <300ms)").tag("groq")
                    Text("OpenAI Whisper API (GPT-Transcribe)").tag("openai")
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

            if transcriptionProvider == "local" {
                Section(header: Text("Local Whisper.cpp Models").bold()) {
                    let binaryFound = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli")
                    HStack {
                        Image(systemName: binaryFound ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(binaryFound ? .green : .orange)
                        Text(binaryFound ? "whisper-cli is installed with Apple Silicon Metal acceleration" : "whisper-cli binary missing. Install via `brew install whisper-cpp`")
                            .font(.subheadline)
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
                                Text("\(model.filename) · \(model.diskSizeString ?? model.estimatedSize)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if model.isInstalled {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
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
            } else if transcriptionProvider == "groq" {
                Section(header: Text("Groq Transcription Settings").bold()) {
                    TextField("Model:", text: $groqModel)
                        .textFieldStyle(.roundedBorder)
                    Text("Recommended: whisper-large-v3-turbo for sub-second cloud transcription.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if transcriptionProvider == "openai" {
                Section(header: Text("OpenAI Transcription Settings").bold()) {
                    TextField("Model:", text: $openaiModel)
                        .textFieldStyle(.roundedBorder)
                    Text("Configured to gpt-4o-transcribe (or fallback to whisper-1).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - LLM & API Keys Tab

    private var llmTab: some View {
        Form {
            Section(header: Text("AI Transcript Refinement").bold()) {
                Toggle("Enable LLM Polish (removes fillers, fixes punctuation & casing)", isOn: $llmEnabled)

                if llmEnabled {
                    Picker("LLM Provider:", selection: $llmProvider) {
                        Text("Groq (Ultra-Fast <200ms)").tag("groq")
                        Text("OpenAI").tag("openai")
                        Text("Anthropic").tag("anthropic")
                    }
                    .pickerStyle(.segmented)

                    TextField("Model Name:", text: $llmModel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section(header: Text("API Keys (.env)").bold()) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("GROQ_API_KEY:")
                            .frame(width: 130, alignment: .leading)
                        if showGroqKey {
                            TextField("gsk_...", text: $groqApiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("gsk_...", text: $groqApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(action: { showGroqKey.toggle() }) {
                            Image(systemName: showGroqKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack {
                        Text("OPENAI_API_KEY:")
                            .frame(width: 130, alignment: .leading)
                        if showOpenAiKey {
                            TextField("sk-...", text: $openaiApiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-...", text: $openaiApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(action: { showOpenAiKey.toggle() }) {
                            Image(systemName: showOpenAiKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack {
                        Text("ANTHROPIC_API_KEY:")
                            .frame(width: 130, alignment: .leading)
                        if showAnthropicKey {
                            TextField("sk-ant-...", text: $anthropicApiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-ant-...", text: $anthropicApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(action: { showAnthropicKey.toggle() }) {
                            Image(systemName: showAnthropicKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Text("Keys are stored locally in ~/.config/shoutflow/.env and never sent to any third party.")
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
            Section(header: Text("System Permissions Status").bold()) {
                HStack {
                    Image(systemName: isAccessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(isAccessibilityGranted ? .green : .red)
                    VStack(alignment: .leading) {
                        Text("Accessibility Permission").bold()
                        Text("Required for global hotkey taps and simulated Cmd+V pasting.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !isAccessibilityGranted {
                        Button("Open Settings") {
                            Permissions.openAccessibilitySettings()
                        }
                        .controlSize(.small)
                    }
                }

                HStack {
                    Image(systemName: isMicrophoneGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(isMicrophoneGranted ? .green : .red)
                    VStack(alignment: .leading) {
                        Text("Microphone Permission").bold()
                        Text("Required to capture dictation audio from your mic.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !isMicrophoneGranted {
                        Button("Grant / Settings") {
                            Permissions.requestMicrophone { _ in
                                refreshPermissionStatus()
                            }
                        }
                        .controlSize(.small)
                    }
                }

                HStack {
                    Image(systemName: "checkmark.shield")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text("Input Monitoring").bold()
                        Text("Required to passively monitor Esc and Fn modifier keys.")
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
                Button("Refresh Permission Status") {
                    refreshPermissionStatus()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack {
            Button("Open Config Folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ConfigManager.configDirectory.path)
            }
            .buttonStyle(.link)
            .font(.caption)

            Spacer()

            if showSaveSuccess {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Saved & Applied!")
                        .font(.caption)
                        .foregroundColor(.green)
                }
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
        cfg.handsFree.autoStopTimeoutSeconds = autoStopMinutes * 60
        cfg.insertion.method = insertionMethod
        cfg.insertion.restoreClipboard = restoreClipboard
        LaunchAtLogin.isEnabled = launchAtLogin

        // Transcription
        cfg.transcription.provider = transcriptionProvider
        cfg.transcription.language = spokenLanguage
        cfg.transcription.groqModel = groqModel
        cfg.transcription.openaiModel = openaiModel

        // LLM
        cfg.llm.enabled = llmEnabled
        cfg.llm.provider = llmProvider
        cfg.llm.model = llmModel
        cfg.llm.systemPrompt = systemPrompt

        ConfigManager.shared.saveConfig(cfg)

        // Save API keys to .env
        ConfigManager.shared.setEnvKey("GROQ_API_KEY", value: groqApiKey)
        ConfigManager.shared.setEnvKey("OPENAI_API_KEY", value: openaiApiKey)
        ConfigManager.shared.setEnvKey("ANTHROPIC_API_KEY", value: anthropicApiKey)

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
