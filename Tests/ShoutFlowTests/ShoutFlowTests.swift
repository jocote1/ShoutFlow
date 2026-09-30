import XCTest
import AppKit
@testable import ShoutFlowCore

final class ShoutFlowTests: XCTestCase {

    func testDefaultConfigValues() {
        let config = ShoutFlowConfig()

        // 1. Hotkey requirements
        XCTAssertEqual(config.hotkey.type, "fn")
        XCTAssertEqual(config.hotkey.doubleTapThresholdMs, 350)

        // 2. Hands-Free 5-minute auto-stop requirement
        XCTAssertEqual(config.handsFree.autoStopTimeoutSeconds, 300, "Hands-free auto-stop should be 300 seconds (5 minutes)")

        // 3. Transcription defaults
        XCTAssertEqual(config.transcription.provider, "local")
        XCTAssertTrue(config.transcription.localModelPath.contains("ggml-small.bin"))
        XCTAssertEqual(config.transcription.openaiModel, "gpt-4o-transcribe")

        // 4. LLM cleanup prompt defaults
        XCTAssertTrue(config.llm.enabled)
        XCTAssertTrue(config.llm.systemPrompt.contains("filler"))
        XCTAssertTrue(config.llm.systemPrompt.contains("punctuation"))

        // 5. Clipboard defaults: leave transcript on clipboard
        XCTAssertFalse(config.insertion.restoreClipboard, "By default, transcript should remain on clipboard")
        XCTAssertEqual(config.insertion.method, "paste")
    }

    func testConfigEncodingDecoding() throws {
        var original = ShoutFlowConfig()
        original.transcription.provider = "groq"
        original.insertion.restoreClipboard = true
        original.handsFree.autoStopTimeoutSeconds = 300

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ShoutFlowConfig.self, from: data)

        XCTAssertEqual(decoded.transcription.provider, "groq")
        XCTAssertEqual(decoded.insertion.restoreClipboard, true)
        XCTAssertEqual(decoded.handsFree.autoStopTimeoutSeconds, 300)
    }

    func testPathResolution() {
        let path = "~/.config/shoutflow/models/ggml-small.bin"
        let resolved = ConfigManager.shared.resolvedPath(path)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(resolved.hasPrefix(home))
        XCTAssertFalse(resolved.contains("~"))
    }

    func testLocalWhisperTranscriptionWithAudio() async throws {
        let modelPath = ConfigManager.shared.resolvedPath("~/.config/shoutflow/models/ggml-small.bin")
        guard FileManager.default.fileExists(atPath: modelPath) else {
            print("Skipping local whisper test: model not installed")
            return
        }

        // Generate synthetic wav file using macOS say and afconvert
        let tempDir = FileManager.default.temporaryDirectory
        let aiffURL = tempDir.appendingPathComponent("unit_test.aiff")
        let wavURL = tempDir.appendingPathComponent("unit_test.wav")

        let sayProcess = Process()
        sayProcess.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        sayProcess.arguments = ["-o", aiffURL.path, "Hello world this is a test"]
        try sayProcess.run()
        sayProcess.waitUntilExit()

        let convertProcess = Process()
        convertProcess.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convertProcess.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiffURL.path, wavURL.path]
        try convertProcess.run()
        convertProcess.waitUntilExit()

        let service = LocalWhisperService(config: ShoutFlowConfig.TranscriptionConfig(
            provider: "local",
            localWhisperBinary: "/opt/homebrew/bin/whisper-cli",
            localModelPath: modelPath
        ))

        let transcript = try await service.transcribe(audioFileURL: wavURL)
        print("Test transcription output: \(transcript)")
        XCTAssertFalse(transcript.isEmpty, "Transcribed text should not be empty")

        // Cleanup
        try? FileManager.default.removeItem(at: aiffURL)
        try? FileManager.default.removeItem(at: wavURL)
    }

    func testClipboardInsertionAndPreservation() {
        let pasteboard = NSPasteboard.general

        // Scenario 1: restoreClipboard = false (leave on clipboard)
        let sample1 = "Transcribed text 1"
        var configNoRestore = ShoutFlowConfig.InsertionConfig()
        configNoRestore.restoreClipboard = false
        TextInserter.shared.insertText(sample1, config: configNoRestore)

        XCTAssertEqual(pasteboard.string(forType: .string), sample1)

        // Scenario 2: restoreClipboard = true
        let previousText = "My original clipboard content"
        pasteboard.clearContents()
        pasteboard.setString(previousText, forType: .string)

        var configRestore = ShoutFlowConfig.InsertionConfig()
        configRestore.restoreClipboard = true
        let sample2 = "Transcribed text 2"
        TextInserter.shared.insertText(sample2, config: configRestore)

        // Give async restore time to run
        let exp = expectation(description: "Clipboard restore")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(pasteboard.string(forType: .string), previousText)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
}
