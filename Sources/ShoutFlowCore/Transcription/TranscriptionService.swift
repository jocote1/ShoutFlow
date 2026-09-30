import Foundation

public enum TranscriptionError: LocalizedError {
    case processFailed(String)
    case cancelled
    case missingAPIKey(String)
    case apiError(String)
    case modelNotFound(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .processFailed(let msg): return "Local Whisper error: \(msg)"
        case .cancelled: return "Transcription was cancelled"
        case .missingAPIKey(let key): return "Missing required API key in .env: \(key)"
        case .apiError(let msg): return "Transcription API error: \(msg)"
        case .modelNotFound(let path): return "Whisper model not found at \(path). Run scripts/download_model.sh"
        case .invalidResponse: return "Received invalid transcription response"
        }
    }
}

public protocol TranscriptionService: AnyObject, Sendable {
    func transcribe(audioFileURL: URL) async throws -> String
    func cancel()
}

// MARK: - Local whisper.cpp Service

public final class LocalWhisperService: TranscriptionService, @unchecked Sendable {
    private var currentProcess: Process?
    private let config: ShoutFlowConfig.TranscriptionConfig

    public init(config: ShoutFlowConfig.TranscriptionConfig) {
        self.config = config
    }

    public func transcribe(audioFileURL: URL) async throws -> String {
        let binaryPath = ConfigManager.shared.resolvedPath(config.localWhisperBinary)
        let modelPath = ConfigManager.shared.resolvedPath(config.localModelPath)

        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath) else {
            throw TranscriptionError.modelNotFound(modelPath)
        }

        var execBinary = binaryPath
        if !fm.fileExists(atPath: execBinary) {
            let candidates = [
                "/opt/homebrew/bin/whisper-cli",
                "/usr/local/bin/whisper-cli",
                "/opt/homebrew/bin/whisper-cpp"
            ]
            if let found = candidates.first(where: { fm.fileExists(atPath: $0) }) {
                execBinary = found
            } else {
                throw TranscriptionError.processFailed("whisper-cli binary not found at \(binaryPath). Install via `brew install whisper-cpp`.")
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: execBinary)

            var arguments = [
                "-m", modelPath,
                "-f", audioFileURL.path,
                "-nt", // no timestamps
                "-np", // no progress prints
                "--suppress-regex", "^\\s*(you|Thank you\\.?|you\\.?)\\s*$"
            ]

            if config.language != "auto" && !config.language.isEmpty {
                arguments += ["--language", config.language]
            }

            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            self.currentProcess = process

            do {
                try process.run()
            } catch {
                self.currentProcess = nil
                continuation.resume(throwing: TranscriptionError.processFailed(error.localizedDescription))
                return
            }

            process.terminationHandler = { [weak self] proc in
                self?.currentProcess = nil

                if proc.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: TranscriptionError.cancelled)
                    return
                }

                let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let stdoutStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderrStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus == 0 {
                    let cleaned = stdoutStr
                        .components(separatedBy: .newlines)
                        .filter { line in
                            let t = line.trimmingCharacters(in: .whitespaces)
                            return !t.hasPrefix("[") && !t.contains("ggml_") && !t.contains("whisper_")
                        }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    let lower = cleaned.lowercased().trimmingCharacters(in: .punctuationCharacters)
                    // If output is a known Whisper hallucination on silence/blank audio, treat as empty
                    if lower == "you" || lower == "thank you" || lower.isEmpty || cleaned.hasPrefix("[") {
                        continuation.resume(returning: "")
                    } else {
                        continuation.resume(returning: cleaned)
                    }
                } else {
                    continuation.resume(throwing: TranscriptionError.processFailed("Status \(proc.terminationStatus): \(stderrStr)"))
                }
            }
        }
    }

    public func cancel() {
        if let proc = currentProcess, proc.isRunning {
            proc.terminate()
            currentProcess = nil
        }
    }
}

// MARK: - Groq Whisper Service

public final class GroqWhisperService: TranscriptionService, @unchecked Sendable {
    private let config: ShoutFlowConfig.TranscriptionConfig

    public init(config: ShoutFlowConfig.TranscriptionConfig) {
        self.config = config
    }

    public func transcribe(audioFileURL: URL) async throws -> String {
        guard let apiKey = ConfigManager.shared.getEnv("GROQ_API_KEY"), !apiKey.isEmpty else {
            throw TranscriptionError.missingAPIKey("GROQ_API_KEY")
        }

        let audioData = try Data(contentsOf: audioFileURL)
        let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendMultipartField(name: "model", value: config.groqModel.isEmpty ? "whisper-large-v3-turbo" : config.groqModel, boundary: boundary)
        body.appendMultipartField(name: "response_format", value: "json", boundary: boundary)
        if config.language != "auto" && !config.language.isEmpty {
            body.appendMultipartField(name: "language", value: config.language, boundary: boundary)
        }
        body.appendMultipartFile(name: "file", filename: audioFileURL.lastPathComponent, mimeType: "audio/wav", fileData: audioData, boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, _) = try await URLSession.shared.data(for: request)

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                throw TranscriptionError.apiError(msg)
            }
            if let text = json["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw TranscriptionError.invalidResponse
    }

    public func cancel() {
        // Automatically cooperative with Task.cancel()
    }
}

// MARK: - OpenAI Whisper Service

public final class OpenAIWhisperService: TranscriptionService, @unchecked Sendable {
    private let config: ShoutFlowConfig.TranscriptionConfig

    public init(config: ShoutFlowConfig.TranscriptionConfig) {
        self.config = config
    }

    public func transcribe(audioFileURL: URL) async throws -> String {
        guard let apiKey = ConfigManager.shared.getEnv("OPENAI_API_KEY"), !apiKey.isEmpty else {
            throw TranscriptionError.missingAPIKey("OPENAI_API_KEY")
        }

        let audioData = try Data(contentsOf: audioFileURL)
        let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let model = config.openaiModel.isEmpty ? "gpt-4o-transcribe" : config.openaiModel
        body.appendMultipartField(name: "model", value: model, boundary: boundary)
        body.appendMultipartField(name: "response_format", value: "json", boundary: boundary)
        if config.language != "auto" && !config.language.isEmpty {
            body.appendMultipartField(name: "language", value: config.language, boundary: boundary)
        }
        body.appendMultipartFile(name: "file", filename: audioFileURL.lastPathComponent, mimeType: "audio/wav", fileData: audioData, boundary: boundary)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, _) = try await URLSession.shared.data(for: request)

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                throw TranscriptionError.apiError(msg)
            }
            if let text = json["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw TranscriptionError.invalidResponse
    }

    public func cancel() {
        // Automatically cooperative with Task.cancel()
    }
}

// MARK: - Multipart Data Helper

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        var str = "--\(boundary)\r\n"
        str += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        str += "\(value)\r\n"
        if let data = str.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendMultipartFile(name: String, filename: String, mimeType: String, fileData: Data, boundary: String) {
        var str = "--\(boundary)\r\n"
        str += "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
        str += "Content-Type: \(mimeType)\r\n\r\n"
        if let data = str.data(using: .utf8) {
            append(data)
        }
        append(fileData)
        append("\r\n".data(using: .utf8)!)
    }
}

// MARK: - Factory

public final class TranscriptionServiceFactory {
    public static func makeService(for config: ShoutFlowConfig.TranscriptionConfig) -> TranscriptionService {
        switch config.provider.lowercased() {
        case "groq":
            return GroqWhisperService(config: config)
        case "openai":
            return OpenAIWhisperService(config: config)
        default:
            return LocalWhisperService(config: config)
        }
    }
}
