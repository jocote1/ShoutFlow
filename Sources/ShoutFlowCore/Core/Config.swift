import Foundation

public struct ShoutFlowConfig: Codable {
    public struct HotkeyConfig: Codable {
        /// Type: "fn" (default) or "shortcut"
        public var type: String
        /// For modifier keys: "fn", "rightCommand", "rightOption", "rightControl"
        /// Or key combos: e.g. modifiers: ["command", "shift"], key: "space"
        public var key: String?
        public var modifiers: [String]?
        /// Double tap detection threshold in milliseconds
        public var doubleTapThresholdMs: Int

        public init(type: String = "fn", key: String? = nil, modifiers: [String]? = nil, doubleTapThresholdMs: Int = 350) {
            self.type = type
            self.key = key
            self.modifiers = modifiers
            self.doubleTapThresholdMs = doubleTapThresholdMs
        }
    }

    public struct HandsFreeConfig: Codable {
        /// Auto-stop timeout in seconds (default: 300 = 5 minutes)
        public var autoStopTimeoutSeconds: Int

        public init(autoStopTimeoutSeconds: Int = 300) {
            self.autoStopTimeoutSeconds = autoStopTimeoutSeconds
        }
    }

    public struct TranscriptionConfig: Codable {
        /// "local" (whisper.cpp), "groq", or "openai"
        public var provider: String
        /// Path to whisper.cpp binary or "whisper-cli"
        public var localWhisperBinary: String
        /// Path to local ggml model file (e.g. ggml-small.bin)
        public var localModelPath: String
        /// Language code: "auto", "en", "no", etc.
        public var language: String
        /// Groq Whisper model (e.g. "whisper-large-v3-turbo")
        public var groqModel: String
        /// OpenAI Whisper model (e.g. "gpt-4o-transcribe" or "whisper-1")
        public var openaiModel: String

        public init(
            provider: String = "local",
            localWhisperBinary: String = "/opt/homebrew/bin/whisper-cli",
            localModelPath: String = "~/.config/shoutflow/models/ggml-small.bin",
            language: String = "auto",
            groqModel: String = "whisper-large-v3-turbo",
            openaiModel: String = "gpt-4o-transcribe"
        ) {
            self.provider = provider
            self.localWhisperBinary = localWhisperBinary
            self.localModelPath = localModelPath
            self.language = language
            self.groqModel = groqModel
            self.openaiModel = openaiModel
        }
    }

    public struct LLMConfig: Codable {
        public var enabled: Bool
        /// "groq", "openai", "anthropic", or "custom"
        public var provider: String
        public var model: String
        public var customBaseUrl: String?
        public var systemPrompt: String

        public init(
            enabled: Bool = true,
            provider: String = "groq",
            model: String = "llama-3.3-70b-versatile",
            customBaseUrl: String? = nil,
            systemPrompt: String = """
            You are an expert dictation assistant.
            Take the raw speech transcript and output a refined, natural text:
            1. Remove verbal fillers and hesitation sounds (such as "um", "uh", "like", "you know", "er", "ah").
            2. Correct punctuation, capitalization, contractions, and sentence boundaries.
            3. Format numbers, dates, currency, and bulleted lists when appropriate.
            4. Match casing and style to smooth dictation.
            5. Strictly preserve the original meaning, tone, intent, and terminology.
            6. Output ONLY the polished dictation text without any preamble, explanation, or quotes.
            """
        ) {
            self.enabled = enabled
            self.provider = provider
            self.model = model
            self.customBaseUrl = customBaseUrl
            self.systemPrompt = systemPrompt
        }
    }

    public struct InsertionConfig: Codable {
        /// "paste" (pasteboard + Cmd-V) or "keystrokes"
        public var method: String
        /// Leave transcript on clipboard (false) or restore previous clipboard (true)
        public var restoreClipboard: Bool
        /// Milliseconds to wait between setting clipboard and triggering paste
        public var pasteDelayMs: Int

        public init(method: String = "paste", restoreClipboard: Bool = false, pasteDelayMs: Int = 50) {
            self.method = method
            self.restoreClipboard = restoreClipboard
            self.pasteDelayMs = pasteDelayMs
        }
    }

    public struct UIConfig: Codable {
        public var showFloatingPill: Bool
        public var pillPosition: String // "bottom" or "top"

        public init(showFloatingPill: Bool = true, pillPosition: String = "bottom") {
            self.showFloatingPill = showFloatingPill
            self.pillPosition = pillPosition
        }
    }

    public var hotkey: HotkeyConfig
    public var handsFree: HandsFreeConfig
    public var transcription: TranscriptionConfig
    public var llm: LLMConfig
    public var insertion: InsertionConfig
    public var ui: UIConfig

    public init(
        hotkey: HotkeyConfig = HotkeyConfig(),
        handsFree: HandsFreeConfig = HandsFreeConfig(),
        transcription: TranscriptionConfig = TranscriptionConfig(),
        llm: LLMConfig = LLMConfig(),
        insertion: InsertionConfig = InsertionConfig(),
        ui: UIConfig = UIConfig()
    ) {
        self.hotkey = hotkey
        self.handsFree = handsFree
        self.transcription = transcription
        self.llm = llm
        self.insertion = insertion
        self.ui = ui
    }
}

public final class ConfigManager {
    public static let shared = ConfigManager()

    public var config: ShoutFlowConfig
    public private(set) var env: [String: String] = [:]

    public func updateTranscriptionProvider(_ provider: String) {
        config.transcription.provider = provider
        saveConfig()
    }

    public static var configDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/shoutflow", isDirectory: true)
    }

    public static var configFileURL: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    public static var envFileURL: URL {
        configDirectory.appendingPathComponent(".env")
    }

    public static var modelsDirectory: URL {
        configDirectory.appendingPathComponent("models", isDirectory: true)
    }

    private init() {
        self.config = ShoutFlowConfig()
        ensureDirectoriesExist()
        loadEnv()
        loadConfig()
    }

    public func ensureDirectoriesExist() {
        let fm = FileManager.default
        try? fm.createDirectory(at: ConfigManager.configDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: ConfigManager.modelsDirectory, withIntermediateDirectories: true)
    }

    public func loadEnv() {
        var merged: [String: String] = [:]

        // Process environment variables
        for (k, v) in ProcessInfo.processInfo.environment {
            merged[k] = v
        }

        // Current working directory .env
        let localEnv = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
        parseEnvFile(at: localEnv, into: &merged)

        // Config directory .env (~/.config/shoutflow/.env)
        parseEnvFile(at: ConfigManager.envFileURL, into: &merged)

        self.env = merged
    }

    private func parseEnvFile(at url: URL, into dict: inout [String: String]) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                var val = parts[1].trimmingCharacters(in: .whitespaces)
                if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                    val = String(val.dropFirst().dropLast())
                }
                dict[key] = val
            }
        }
    }

    public func loadConfig() {
        ensureDirectoriesExist()
        let url = ConfigManager.configFileURL
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            // Write default config
            saveConfig(self.config)
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            self.config = try decoder.decode(ShoutFlowConfig.self, from: data)
        } catch {
            print("[ShoutFlow] Error decoding config.json: \(error). Using default configuration.")
        }
    }

    public func setEnvKey(_ key: String, value: String) {
        env[key] = value
        saveEnv()
    }

    public func saveEnv() {
        ensureDirectoriesExist()
        let allowedKeys: Set<String> = ["GROQ_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "LLM_API_KEY"]
        var lines: [String] = [
            "# ShoutFlow Environment Configuration",
            "# Updated via ShoutFlow Settings Window",
            ""
        ]
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            if allowedKeys.contains(k) && !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("\(k)=\(v)")
            }
        }
        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(to: ConfigManager.envFileURL, atomically: true, encoding: .utf8)
    }

    public func saveConfig(_ newConfig: ShoutFlowConfig? = nil) {
        if let newConfig = newConfig {
            self.config = newConfig
        }
        ensureDirectoriesExist()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self.config) {
            try? data.write(to: ConfigManager.configFileURL)
        }
    }

    public func getEnv(_ key: String) -> String? {
        if let val = env[key], !val.isEmpty {
            return val
        }
        loadEnv()
        if let val = env[key], !val.isEmpty {
            return val
        }
        return ProcessInfo.processInfo.environment[key]
    }

    public func resolvedPath(_ path: String) -> String {
        var p = path
        if p.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            p = home + p.dropFirst()
        }
        return (p as NSString).standardizingPath
    }
}
