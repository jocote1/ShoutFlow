import XCTest
import AppKit
@testable import ShoutFlowCore

final class ShoutFlowTests: XCTestCase {

    func testDefaultConfigValues() {
        let config = ShoutFlowConfig()

        // 1. Hotkey requirements
        XCTAssertEqual(config.hotkey.type, "fn")
        XCTAssertEqual(config.hotkey.doubleTapThresholdMs, 350)
        XCTAssertTrue(config.hotkey.tripleTapToCancel, "Triple-tap to cancel should be enabled by default")

        // 2. Hands-Free 5-minute auto-stop requirement
        XCTAssertEqual(config.handsFree.autoStopTimeoutSeconds, 300, "Hands-free auto-stop should be 300 seconds (5 minutes)")

        // 3. Transcription defaults (Priority: local -> groq -> openai)
        XCTAssertEqual(config.transcription.provider, "priority")
        XCTAssertTrue(config.transcription.localModelPath.contains("ggml-small.bin"))
        XCTAssertEqual(config.transcription.groqModel, "whisper-large-v3-turbo")
        XCTAssertEqual(config.transcription.openaiModel, "gpt-4o-transcribe")

        // 4. LLM cleanup prompt & cost guardrail defaults
        XCTAssertTrue(config.llm.enabled)
        XCTAssertEqual(config.llm.temperature, 0.0, "Temperature should be 0.0 to prevent drift and hallucination")
        XCTAssertTrue(config.llm.bypassShortPhrases, "Short and clean phrases should bypass LLM for efficiency")
        XCTAssertTrue(config.llm.systemPrompt.contains("filler"))
        XCTAssertTrue(config.llm.systemPrompt.contains("punctuation"))

        // 5. Sound effects default
        XCTAssertTrue(config.ui.soundEffectsEnabled, "Audio chimes should be enabled by default")

        // 6. Clipboard defaults: leave transcript on clipboard
        XCTAssertFalse(config.insertion.restoreClipboard, "By default, transcript should remain on clipboard")
        XCTAssertEqual(config.insertion.method, "paste")
    }

    func testLLMShortPhraseAndFillerBypass() {
        let service = LLMService(config: ShoutFlowConfig.LLMConfig(enabled: true, bypassShortPhrases: true))

        // 1. Phrases under 4 words should ALWAYS bypass LLM
        XCTAssertTrue(service.shouldBypassLLM(for: "Hello"))
        XCTAssertTrue(service.shouldBypassLLM(for: "Yes please"))
        XCTAssertTrue(service.shouldBypassLLM(for: "Quick brown fox"))

        // 2. Phrases 4+ words without fillers should bypass LLM
        XCTAssertTrue(service.shouldBypassLLM(for: "The quarterly report is finished now."))
        XCTAssertTrue(service.shouldBypassLLM(for: "Please send this document to Ole right away."))

        // 3. Phrases with filler words should NOT bypass LLM (they need cleaning!)
        XCTAssertFalse(service.shouldBypassLLM(for: "So basically um we need to finish this."))
        XCTAssertFalse(service.shouldBypassLLM(for: "I think uh we should do that tomorrow."))
        XCTAssertFalse(service.shouldBypassLLM(for: "It was like really cool you know?"))
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

    func testModelManagerDetectionAndActivation() {
        let models = ModelManager.availableModels
        XCTAssertGreaterThan(models.count, 2)

        // Find small model
        guard let small = models.first(where: { $0.id == "small" }) else {
            XCTFail("Small model should exist in available models")
            return
        }

        XCTAssertTrue(small.isInstalled, "Small model was downloaded and should be marked as installed")
        XCTAssertNotNil(small.diskSizeString)

        // Test activation
        ModelManager.shared.setActiveModel(small)
        XCTAssertTrue(ModelManager.shared.isModelActive(small))
    }

    func testEnvKeySavingAndLoading() {
        let testKey = "TEST_API_KEY_\(UUID().uuidString.prefix(6))"
        let testVal = "secret_12345"

        ConfigManager.shared.setEnvKey(testKey, value: testVal)
        XCTAssertEqual(ConfigManager.shared.getEnv(testKey), testVal)
    }

    func testArrowKeysDoNotTriggerFnHotkey() {
        // macOS sets maskSecondaryFn (bit 23 / 0x800000) on all arrow keys (Left, Right, Up, Down), Page Up/Down, etc.
        // We must ensure that Left Arrow (keyCode 123) and other arrow keys NEVER evaluate to pressing the Fn hotkey!
        let arrowFlags = CGEventFlags(rawValue: 0x800000) // maskSecondaryFn

        // Left Arrow keyDown (keyCode 123)
        let leftArrowResult = HotKeyMonitor.evaluateKeyIsPressed(
            hotkeyType: "fn",
            flags: arrowFlags,
            keyCode: 123,
            isFlagsChanged: false,
            isKeyDownEvent: true,
            isCurrentlyPressed: false
        )
        XCTAssertNil(leftArrowResult, "Left Arrow keyDown should be ignored and never trigger Fn hotkey")

        // Right Arrow keyDown (keyCode 124)
        let rightArrowResult = HotKeyMonitor.evaluateKeyIsPressed(
            hotkeyType: "fn",
            flags: arrowFlags,
            keyCode: 124,
            isFlagsChanged: false,
            isKeyDownEvent: true,
            isCurrentlyPressed: false
        )
        XCTAssertNil(rightArrowResult, "Right Arrow keyDown should be ignored and never trigger Fn hotkey")

        // Down Arrow keyDown (keyCode 125)
        let downArrowResult = HotKeyMonitor.evaluateKeyIsPressed(
            hotkeyType: "fn",
            flags: arrowFlags,
            keyCode: 125,
            isFlagsChanged: false,
            isKeyDownEvent: true,
            isCurrentlyPressed: false
        )
        XCTAssertNil(downArrowResult, "Down Arrow keyDown should be ignored and never trigger Fn hotkey")

        // Real Fn Key (keyCode 63, flagsChanged) SHOULD evaluate to pressed: true
        let realFnResult = HotKeyMonitor.evaluateKeyIsPressed(
            hotkeyType: "fn",
            flags: arrowFlags,
            keyCode: 63,
            isFlagsChanged: true,
            isKeyDownEvent: false,
            isCurrentlyPressed: false
        )
        XCTAssertEqual(realFnResult, true, "Physical Fn key press (keyCode 63, flagsChanged) should trigger hotkey")

        // Real Fn Key release (keyCode 63, flagsChanged, no fn flag) SHOULD evaluate to pressed: false
        let realFnReleaseResult = HotKeyMonitor.evaluateKeyIsPressed(
            hotkeyType: "fn",
            flags: CGEventFlags(),
            keyCode: 63,
            isFlagsChanged: true,
            isKeyDownEvent: false,
            isCurrentlyPressed: true
        )
        XCTAssertEqual(realFnReleaseResult, false, "Physical Fn key release should evaluate to false")
    }
}
