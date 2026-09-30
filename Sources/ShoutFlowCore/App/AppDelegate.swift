import AppKit
import AVFoundation

public final class AppDelegate: NSObject, NSApplicationDelegate, HotKeyMonitorDelegate, StatusBarMenuDelegate {
    private var statusBarMenu: StatusBarMenu!
    private var hotKeyMonitor: HotKeyMonitor!
    private var pillWindow: FloatingPillWindowController!

    private var currentTranscriptionService: TranscriptionService?
    private var currentLLMService: LLMService?
    private var activeProcessingTask: Task<Void, Never>?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (agent app / LSUIElement)
        NSApp.setActivationPolicy(.accessory)

        pillWindow = FloatingPillWindowController.shared
        statusBarMenu = StatusBarMenu()
        statusBarMenu.delegate = self

        hotKeyMonitor = HotKeyMonitor()
        hotKeyMonitor.delegate = self
        hotKeyMonitor.start()

        setupServices()

        // Permissions check on first launch
        checkInitialPermissions()

        print("[ShoutFlow] ShoutFlow is running in background. Hold Fn to talk, double-tap Fn for hands-free, Esc to cancel.")
    }

    private func setupServices() {
        let config = ConfigManager.shared.config
        currentTranscriptionService = TranscriptionServiceFactory.makeService(for: config.transcription)
        currentLLMService = LLMService(config: config.llm)
    }

    private func checkInitialPermissions() {
        if !Permissions.isAccessibilityGranted {
            Permissions.requestAccessibility()
        }
        if !Permissions.isMicrophoneGranted {
            Permissions.requestMicrophone { granted in
                print("[ShoutFlow] Microphone permission status: \(granted)")
            }
        }
    }

    // MARK: - HotKeyMonitorDelegate

    public func hotKeyDidBeginHold() {
        guard statusBarMenu.isEnabled else { return }

        // Cancel any pending task
        cancelCurrentOperation(notifyPill: false)

        do {
            _ = try AudioRecorder.shared.startRecording()
            if ConfigManager.shared.config.ui.showFloatingPill {
                pillWindow.updateState(.holdToTalk)
            }
        } catch {
            print("[ShoutFlow] Failed to start audio recording: \(error.localizedDescription)")
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
            } catch {
                print("[ShoutFlow] Failed to start audio recording for hands-free: \(error.localizedDescription)")
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
        print("[ShoutFlow] Esc pressed: Canceling ongoing recording or transcription.")
        cancelCurrentOperation(notifyPill: true)
    }

    // MARK: - Pipeline: Record -> Transcribe -> LLM Clean -> Paste

    private func processRecordingAndPaste() {
        guard let audioURL = AudioRecorder.shared.stopRecording() else {
            hotKeyMonitor.setIdleState()
            pillWindow.updateState(.hidden)
            return
        }

        if ConfigManager.shared.config.ui.showFloatingPill {
            pillWindow.updateState(.transcribing)
        }

        setupServices()

        activeProcessingTask?.cancel()
        activeProcessingTask = Task { [weak self] in
            guard let self = self else { return }

            defer {
                // Cleanup temp audio file
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
                let rawTranscript = try await service.transcribe(audioFileURL: audioURL)
                let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !trimmed.isEmpty else {
                    print("[ShoutFlow] Transcript was empty. Nothing to insert.")
                    await MainActor.run {
                        self.pillWindow.updateState(.hidden)
                    }
                    return
                }

                print("[ShoutFlow] Raw Transcript: \(trimmed)")

                // 2. LLM Post-Processing (filler removal, punctuation, casing)
                let cleanedText: String
                if ConfigManager.shared.config.llm.enabled, let llm = self.currentLLMService {
                    await MainActor.run {
                        self.pillWindow.updateState(.cleaning)
                    }
                    cleanedText = await llm.cleanTranscript(trimmed)
                } else {
                    cleanedText = trimmed
                }

                print("[ShoutFlow] Cleaned Output: \(cleanedText)")

                // Check if cancelled before pasting
                try Task.checkCancellation()

                // 3. Insert into active app (via Pasteboard + Cmd-V or Keystrokes)
                await MainActor.run {
                    TextInserter.shared.insertText(cleanedText, config: ConfigManager.shared.config.insertion)
                    if ConfigManager.shared.config.ui.showFloatingPill {
                        self.pillWindow.updateState(.done)
                    }
                }
            } catch is CancellationError {
                print("[ShoutFlow] Task was cancelled.")
                await MainActor.run {
                    self.pillWindow.updateState(.canceled)
                }
            } catch {
                print("[ShoutFlow] Transcription error: \(error.localizedDescription)")
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

        if notifyPill && ConfigManager.shared.config.ui.showFloatingPill {
            pillWindow.updateState(.canceled)
        } else {
            pillWindow.updateState(.hidden)
        }
    }

    // MARK: - StatusBarMenuDelegate

    public func statusBarDidToggleEnabled(_ isEnabled: Bool) {
        if !isEnabled {
            cancelCurrentOperation(notifyPill: true)
        }
    }

    public func statusBarDidChangeProvider(_ provider: String) {
        setupServices()
    }
}
