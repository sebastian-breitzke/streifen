import Foundation

final class StreifenLogger: Sendable {
    static let shared = StreifenLogger()

    private let logFile: URL

    private init() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Streifen", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        logFile = logDir.appendingPathComponent("streifen.log")

        // Rotate if > 5MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? Int, size > 5_000_000 {
            let backup = logDir.appendingPathComponent("streifen.log.1")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: logFile, to: backup)
        }

        write("--- Streifen started (pid \(ProcessInfo.processInfo.processIdentifier)) ---")
    }

    func log(_ message: String) {
        NSLog("[Streifen] %@", message)
        write(message)
    }

    private func write(_ message: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(df.string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: logFile) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                // Create file if it doesn't exist
                try? data.write(to: logFile)
            }
        }
    }
}

/// Global shorthand
func slog(_ message: String) {
    StreifenLogger.shared.log(message)
}
