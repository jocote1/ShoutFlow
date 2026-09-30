import Foundation

public final class LLMService: @unchecked Sendable {
    private var currentTask: URLSessionDataTask?
    private let config: ShoutFlowConfig.LLMConfig

    public init(config: ShoutFlowConfig.LLMConfig) {
        self.config = config
    }

    public func cleanTranscript(_ rawText: String) async -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.enabled, !trimmed.isEmpty else {
            return rawText
        }

        // Efficiency & Cost Guardrail: Bypass LLM if short or no fillers
        if config.bypassShortPhrases && shouldBypassLLM(for: trimmed) {
            AppLogger.shared.log("[LLM] Bypassing post-processing: transcript is under 4 words or contains zero filler words. Zero latency & cost.")
            return rawText
        }

        do {
            return try await processWithLLM(trimmed)
        } catch {
            AppLogger.shared.log("[LLM] Post-processing fallback: \(error.localizedDescription). Using raw transcript.")
            return rawText
        }
    }

    public func shouldBypassLLM(for text: String) -> Bool {
        let words = text.split { $0.isWhitespace }
        if words.count < 4 {
            return true
        }

        let lower = text.lowercased()
        let fillerPatterns = [
            "\\bum\\b", "\\buh\\b", "\\blike\\b", "\\byou know\\b",
            "\\ber\\b", "\\bah\\b", "\\bhmm\\b", "\\bso basically\\b",
            "\\bi mean\\b", "\\bsort of\\b", "\\bkind of\\b"
        ]

        let hasFiller = fillerPatterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern).firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower))) != nil
        }

        return !hasFiller
    }

    private func processWithLLM(_ rawText: String) async throws -> String {
        let provider = config.provider.lowercased()
        let apiKey: String?
        let endpointURL: URL

        switch provider {
        case "groq":
            apiKey = ConfigManager.shared.getEnv("GROQ_API_KEY")
            endpointURL = URL(string: config.customBaseUrl ?? "https://api.groq.com/openai/v1/chat/completions")!
        case "openai":
            apiKey = ConfigManager.shared.getEnv("OPENAI_API_KEY")
            endpointURL = URL(string: config.customBaseUrl ?? "https://api.openai.com/v1/chat/completions")!
        case "anthropic":
            apiKey = ConfigManager.shared.getEnv("ANTHROPIC_API_KEY")
            endpointURL = URL(string: config.customBaseUrl ?? "https://api.anthropic.com/v1/messages")!
        default:
            apiKey = ConfigManager.shared.getEnv("LLM_API_KEY") ?? ConfigManager.shared.getEnv("OPENAI_API_KEY") ?? ConfigManager.shared.getEnv("GROQ_API_KEY")
            endpointURL = URL(string: config.customBaseUrl ?? "https://api.groq.com/openai/v1/chat/completions")!
        }

        guard let key = apiKey, !key.isEmpty else {
            AppLogger.shared.log("[LLM] No API key available for LLM provider '\(provider)'. Returning raw transcript.")
            return rawText
        }

        if provider == "anthropic" {
            return try await callAnthropic(rawText: rawText, apiKey: key, endpoint: endpointURL)
        } else {
            return try await callOpenAICompatible(rawText: rawText, apiKey: key, endpoint: endpointURL)
        }
    }

    private func callOpenAICompatible(rawText: String, apiKey: String, endpoint: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15.0

        let provider = config.provider.lowercased()
        let defaultModel: String
        if provider == "openai" {
            defaultModel = "gpt-4o-mini"
        } else {
            defaultModel = "llama-3.1-8b-instant"
        }

        let model = config.model.isEmpty ? defaultModel : config.model

        // Dynamic max_tokens based on word count
        let wordCount = rawText.split { $0.isWhitespace }.count
        let dynamicMaxTokens = max(32, min(1024, Int(Double(wordCount) * 2.5) + 30))

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": config.systemPrompt],
                ["role": "user", "content": rawText]
            ],
            "temperature": config.temperature, // 0.0 to prevent drift and reduce generation cycles
            "max_tokens": dynamicMaxTokens
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await URLSession.shared.data(for: request)

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                AppLogger.shared.log("[LLM] API returned error: \(msg)")
                return rawText
            }

            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? rawText : cleaned
            }
        }
        return rawText
    }

    private func callAnthropic(rawText: String, apiKey: String, endpoint: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15.0

        let wordCount = rawText.split { $0.isWhitespace }.count
        let dynamicMaxTokens = max(32, min(1024, Int(Double(wordCount) * 2.5) + 30))

        let payload: [String: Any] = [
            "model": config.model.isEmpty ? "claude-3-5-haiku-20241022" : config.model,
            "max_tokens": dynamicMaxTokens,
            "system": config.systemPrompt,
            "messages": [
                ["role": "user", "content": rawText]
            ],
            "temperature": config.temperature // 0.0
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await URLSession.shared.data(for: request)

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let contentBlocks = json["content"] as? [[String: Any]],
           let first = contentBlocks.first,
           let text = first["text"] as? String {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? rawText : cleaned
        }
        return rawText
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}
