import Foundation

public final class AppLogger {
    public static let shared = AppLogger()

    public static var logFileURL: URL {
        ConfigManager.configDirectory.appendingPathComponent("shoutflow.log")
    }

    private let queue = DispatchQueue(label: "no.hnhvgs.shoutflow.logger")
    private let dateFormatter: DateFormatter

    private init() {
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        ConfigManager.shared.ensureDirectoriesExist()
    }

    public func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        // Also print to standard output
        print("[ShoutFlow] \(message)")

        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let url = AppLogger.logFileURL

            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
