import AppKit
import AVFoundation

public final class AppDelegate: NSObject, NSApplicationDelegate, HotKeyMonitorDelegate, StatusBarMenuDelegate {
    public static private(set) var shared: AppDelegate?

    public private(set) var statusBarMenu: StatusBarMenu!
    public private(set) var hotKeyMonitor: HotKeyMonitor!
    public private(set) var pillWindow: FloatingPillWindowController!

    private var currentTranscriptionService: TranscriptionService?
    private var currentLLMService: LLMService?
    private var activeProcessingTask: Task<Void, Never>?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Hide dock icon (agent app / LSUIElement)
        NSApp.setActivationPolicy(.accessory)

        pillWindow = FloatingPillWindowController.shared
        statusBarMenu = StatusBarMenu()
        statusBarMenu.delegate = self

        hotKeyMonitor = HotKeyMonitor()
        hotKeyMonitor.delegate = self
        hotKeyMonitor.start()

        setupServices()

        AppLogger.shared.log("ShoutFlow started. Config dir: \(ConfigManager.configDirectory.path)")
        AppLogger.shared.log("Accessibility granted: \(Permissions.isAccessibilityGranted), Microphone granted: \(Permissions.isMicrophoneGranted)")

        // Permissions check and prompt on first launch
        checkInitialPermissions()
    }

    public func setupServices() {
        let config = ConfigManager.shared.config
        currentTranscriptionService = TranscriptionServiceFactory.makeService(for: config.transcription)
        currentLLMService = LLMService(config: config.llm)
        AppLogger.shared.log("Services configured: Provider=\(config.transcription.provider), Model=\(config.transcription.localModelPath), LLM=\(config.llm.enabled)")
    }

    private func checkInitialPermissions() {
        if !Permissions.isAccessibilityGranted {
            AppLogger.shared.log("Requesting Accessibility permission...")
            Permissions.requestAccessibility()
        }
        if !Permissions.isMicrophoneGranted {
            AppLogger.shared.log("Requesting Microphone permission...")
            Permissions.requestMicrophone { granted in
                AppLogger.shared.log("Microphone permission granted: \(granted)")
            }
        }
    }

    // MARK: - Manual / Test Dictation Trigger

    public func toggleManualDictation() {
        if AudioRecorder.shared.isRecording {
            AppLogger.shared.log("[Manual] Stopping manual recording session...")
            processRecordingAndPaste()
            statusBarMenu.setManualRecordingState(isRecording: false)
        } else {
            AppLogger.shared.log("[Manual] Starting manual recording session...")
            hotKeyDidBeginHold()
            statusBarMenu.setManualRecordingState(isRecording: true)
        }
    }

    // MARK: - HotKeyMonitorDelegate

    public func hotKeyDidBeginHold() {
        guard statusBarMenu.isEnabled else { return }

        // Cancel any pending in-flight transcription or LLM task
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        currentTranscriptionService?.cancel()
        currentLLMService?.cancel()

        if AudioRecorder.shared.isRecording {
            _ = AudioRecorder.shared.stopRecording()
        }

        do {
            let fileURL = try AudioRecorder.shared.startRecording()
            AppLogger.shared.log("[Audio] Recording started -> \(fileURL.lastPathComponent)")
            if ConfigManager.shared.config.ui.showFloatingPill {
                pillWindow.updateState(.holdToTalk)
            }
        } catch {
            AppLogger.shared.log("[Audio] Failed to start audio recording: \(error.localizedDescription)")
            hotKeyMonitor.setIdleState()
        }
    }

    public func hotKeyDidReleaseHold() {
        guard statusBarMenu.isEnabled else { return }
        processRecordingAndPaste()
    }

    public func hotKeyDidEnterHandsFree() {
        guard statusBarMenu.isEnabled else { return }

        if !AudioRecorder.shared.isRecording {
            do {
                _ = try AudioRecorder.shared.startRecording()
                AppLogger.shared.log("[Audio] Hands-free recording started")
            } catch {
                AppLogger.shared.log("[Audio] Failed to start audio recording for hands-free: \(error.localizedDescription)")
                hotKeyMonitor.setIdleState()
                return
            }
        }

        let maxSec = ConfigManager.shared.config.handsFree.autoStopTimeoutSeconds
        if ConfigManager.shared.config.ui.showFloatingPill {
            pillWindow.updateState(.handsFree(elapsedSeconds: 0, maxSeconds: maxSec))
        }
    }

    public func handsFreeTimerDidTick(elapsedSeconds: Int, maxSeconds: Int) {
        guard statusBarMenu.isEnabled else { return }
        if ConfigManager.shared.config.ui.showFloatingPill {
            pillWindow.updateState(.handsFree(elapsedSeconds: elapsedSeconds, maxSeconds: maxSeconds))
        }
    }

    public func hotKeyDidExitHandsFree() {
        guard statusBarMenu.isEnabled else { return }
        processRecordingAndPaste()
    }

    public func hotKeyDidCancel() {
        AppLogger.shared.log("[Pipeline] Operation cancelled via Esc")
        cancelCurrentOperation(notifyPill: true)
    }

    // MARK: - Pipeline: Record -> Transcribe -> LLM Clean -> Paste

    private func processRecordingAndPaste() {
        statusBarMenu.setManualRecordingState(isRecording: false)

        guard let audioURL = AudioRecorder.shared.stopRecording() else {
            hotKeyMonitor.setIdleState()
            pillWindow.updateState(.hidden)
            return
        }

        AppLogger.shared.log("[Audio] Recording stopped. Beginning transcription pipeline...")

        if ConfigManager.shared.config.ui.showFloatingPill {
            pillWindow.updateState(.transcribing)
        }

        setupServices()

        activeProcessingTask?.cancel()
        activeProcessingTask = Task { [weak self] in
            guard let self = self else { return }

            defer {
                try? FileManager.default.removeItem(at: audioURL)
                Task { @MainActor in
                    self.hotKeyMonitor.setIdleState()
                }
            }

            do {
                guard let service = self.currentTranscriptionService else {
                    throw TranscriptionError.invalidResponse
                }

                // 1. Transcribe audio
                AppLogger.shared.log("[Pipeline] Transcribing audio with \(ConfigManager.shared.config.transcription.provider)...")
                let rawTranscript = try await service.transcribe(audioFileURL: audioURL)
                let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !trimmed.isEmpty else {
                    AppLogger.shared.log("[Pipeline] Transcript was empty (no speech detected).")
                    await MainActor.run {
                        self.pillWindow.updateState(.hidden)
                    }
                    return
                }

                AppLogger.shared.log("[Pipeline] Raw Transcript: \"\(trimmed)\"")

                // 2. LLM Post-Processing (filler removal, punctuation, casing)
                let cleanedText: String
                if ConfigManager.shared.config.llm.enabled, let llm = self.currentLLMService {
                    await MainActor.run {
                        self.pillWindow.updateState(.cleaning)
                    }
                    AppLogger.shared.log("[Pipeline] Refining transcript with LLM (\(ConfigManager.shared.config.llm.provider))...")
                    cleanedText = await llm.cleanTranscript(trimmed)
                } else {
                    cleanedText = trimmed
                }

                AppLogger.shared.log("[Pipeline] Final Cleaned Output: \"\(cleanedText)\"")

                try Task.checkCancellation()

                // 3. Insert into active app (via Pasteboard + Cmd-V or Keystrokes)
                await MainActor.run {
                    TextInserter.shared.insertText(cleanedText, config: ConfigManager.shared.config.insertion)
                    if ConfigManager.shared.config.ui.showFloatingPill {
                        self.pillWindow.updateState(.done)
                    }
                }
                AppLogger.shared.log("[Pipeline] Successfully inserted text!")
            } catch is CancellationError {
                AppLogger.shared.log("[Pipeline] Task cancelled.")
                await MainActor.run {
                    self.pillWindow.updateState(.canceled)
                }
            } catch {
                AppLogger.shared.log("[Pipeline] Error: \(error.localizedDescription)")
                await MainActor.run {
                    self.pillWindow.updateState(.canceled)
                }
            }
        }
    }

    private func cancelCurrentOperation(notifyPill: Bool) {
        AudioRecorder.shared.cancelRecording()
        currentTranscriptionService?.cancel()
        currentLLMService?.cancel()
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        hotKeyMonitor.setIdleState()
        statusBarMenu.setManualRecordingState(isRecording: false)

        if notifyPill && ConfigManager.shared.config.ui.showFloatingPill {
            pillWindow.updateState(.canceled)
        } else {
            pillWindow.updateState(.hidden)
        }
    }

    // MARK: - StatusBarMenuDelegate

    public func statusBarDidToggleEnabled(_ isEnabled: Bool) {
        AppLogger.shared.log("ShoutFlow enabled state changed to: \(isEnabled)")
        if !isEnabled {
            cancelCurrentOperation(notifyPill: true)
        }
    }

    public func statusBarDidChangeProvider(_ provider: String) {
        setupServices()
    }
}
