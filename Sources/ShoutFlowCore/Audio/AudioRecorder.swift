import Foundation
import AVFoundation

public final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    public static let shared = AudioRecorder()

    private var audioRecorder: AVAudioRecorder?
    private var currentFileURL: URL?
    public private(set) var isRecording = false

    private let audioSessionQueue = DispatchQueue(label: "no.hnhvgs.shoutflow.audio")

    override private init() {
        super.init()
    }

    public func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    public func startRecording() throws -> URL {
        if isRecording {
            _ = stopRecording()
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ShoutFlow", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileURL = tempDir.appendingPathComponent("recording_\(UUID().uuidString).wav")
        self.currentFileURL = fileURL

        // Whisper requires 16000Hz, 16-bit Mono Linear PCM
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw NSError(domain: "ShoutFlowAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start audio recording"])
        }

        self.audioRecorder = recorder
        self.isRecording = true
        return fileURL
    }

    public func stopRecording() -> URL? {
        guard isRecording, let recorder = audioRecorder else {
            return nil
        }

        recorder.updateMeters()
        let avgPower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)
        let duration = recorder.currentTime

        recorder.stop()
        isRecording = false
        audioRecorder = nil

        AppLogger.shared.log(String(format: "[Audio] Recording stopped. Duration: %.2fs, AvgPower: %.1f dB, PeakPower: %.1f dB", duration, avgPower, peakPower))

        // If audio is digitally silent (-100 dB or less, e.g. AirPods in case), trigger fallback to built-in mic
        if avgPower <= -100.0 {
            AppLogger.shared.log("[Audio] WARNING: Audio stream is digitally silent (power: \(avgPower) dB). Fallback check for built-in microphone...")
            AudioDeviceManager.shared.fallbackToBuiltinMicrophoneIfNeeded()
        }

        let recordedURL = currentFileURL
        return recordedURL
    }

    public func cancelRecording() {
        if isRecording {
            audioRecorder?.stop()
            isRecording = false
            audioRecorder = nil
        }
        if let fileURL = currentFileURL {
            try? FileManager.default.removeItem(at: fileURL)
            currentFileURL = nil
        }
    }

    /// Returns a normalized audio level [0.0 ... 1.0] for UI visualizer
    public func getAudioLevel() -> Float {
        guard isRecording, let recorder = audioRecorder else {
            return 0.0
        }
        recorder.updateMeters()
        let avgPower = recorder.averagePower(forChannel: 0) // Typically -160 to 0 dB
        // Map -50 dB ... 0 dB to 0.0 ... 1.0
        let minDb: Float = -50.0
        if avgPower < minDb {
            return 0.05
        } else if avgPower >= 0.0 {
            return 1.0
        } else {
            let level = (avgPower - minDb) / (0.0 - minDb)
            return max(0.05, min(1.0, level))
        }
    }
}
