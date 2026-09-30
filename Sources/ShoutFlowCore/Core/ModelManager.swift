import Foundation
import AppKit

public struct WhisperModelInfo: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let filename: String
    public let estimatedSize: String
    public let downloadURL: URL

    public init(id: String, name: String, filename: String, estimatedSize: String) {
        self.id = id
        self.name = name
        self.filename = filename
        self.estimatedSize = estimatedSize
        self.downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    public var localURL: URL {
        ConfigManager.modelsDirectory.appendingPathComponent(filename)
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }

    public var diskSizeString: String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: size)
    }
}

public final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = ModelManager()

    public static let availableModels: [WhisperModelInfo] = [
        WhisperModelInfo(id: "small", name: "Small (Recommended)", filename: "ggml-small.bin", estimatedSize: "~461 MB"),
        WhisperModelInfo(id: "medium", name: "Medium (Higher Accuracy)", filename: "ggml-medium.bin", estimatedSize: "~1.4 GB"),
        WhisperModelInfo(id: "base", name: "Base (Fastest)", filename: "ggml-base.bin", estimatedSize: "~141 MB"),
        WhisperModelInfo(id: "tiny", name: "Tiny (Minimal)", filename: "ggml-tiny.bin", estimatedSize: "~75 MB"),
        WhisperModelInfo(id: "large-v3", name: "Large v3 (Maximum)", filename: "ggml-large-v3.bin", estimatedSize: "~3.1 GB")
    ]

    @Published public var currentlyDownloadingModelId: String? = nil
    @Published public var downloadProgress: Double = 0.0
    @Published public var lastConfirmationMessage: String? = nil

    private var activeDownloadTask: URLSessionDownloadTask?
    private var downloadCompletion: ((Result<URL, Error>) -> Void)?
    private var targetModel: WhisperModelInfo?

    override private init() {
        super.init()
    }

    public func isModelActive(_ model: WhisperModelInfo) -> Bool {
        let activePath = ConfigManager.shared.resolvedPath(ConfigManager.shared.config.transcription.localModelPath)
        return activePath == model.localURL.path || activePath.hasSuffix("/" + model.filename)
    }

    public func setActiveModel(_ model: WhisperModelInfo) {
        ConfigManager.shared.config.transcription.localModelPath = model.localURL.path
        ConfigManager.shared.saveConfig()
        lastConfirmationMessage = "Active model set to \(model.name)"
    }

    public func downloadModel(_ model: WhisperModelInfo, completion: ((Result<URL, Error>) -> Void)? = nil) {
        guard currentlyDownloadingModelId == nil else {
            completion?(.failure(NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another download is already in progress"])))
            return
        }

        self.targetModel = model
        self.currentlyDownloadingModelId = model.id
        self.downloadProgress = 0.0
        self.downloadCompletion = completion

        ConfigManager.shared.ensureDirectoriesExist()

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        let task = session.downloadTask(with: model.downloadURL)
        self.activeDownloadTask = task
        task.resume()
    }

    public func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        currentlyDownloadingModelId = nil
        downloadProgress = 0.0
        targetModel = nil
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async {
                self.downloadProgress = progress
            }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = targetModel else { return }

        let destURL = model.localURL
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: location, to: destURL)

            DispatchQueue.main.async {
                self.currentlyDownloadingModelId = nil
                self.downloadProgress = 1.0

                // Automatically activate downloaded model
                self.setActiveModel(model)

                let msg = "✓ Model '\(model.name)' downloaded successfully and activated for offline transcription!"
                self.lastConfirmationMessage = msg

                // Show native macOS confirmation dialog
                let alert = NSAlert()
                alert.messageText = "Model Download Complete"
                alert.informativeText = "Whisper model '\(model.filename)' has been downloaded and verified (\(model.diskSizeString ?? model.estimatedSize)).\n\nShoutFlow is now ready for offline local dictation!"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()

                self.downloadCompletion?(.success(destURL))
            }
        } catch {
            DispatchQueue.main.async {
                self.currentlyDownloadingModelId = nil
                self.downloadCompletion?(.failure(error))

                let alert = NSAlert()
                alert.messageText = "Download Error"
                alert.informativeText = "Failed to save downloaded model: \(error.localizedDescription)"
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError?, error.code != NSURLErrorCancelled {
            DispatchQueue.main.async {
                self.currentlyDownloadingModelId = nil
                self.downloadProgress = 0.0
                self.downloadCompletion?(.failure(error))

                let alert = NSAlert()
                alert.messageText = "Download Failed"
                alert.informativeText = "Could not download model: \(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}
