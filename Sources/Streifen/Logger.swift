import Foundation

/// JSONL structured logger for Streifen.
///
/// Writes one JSON object per line to `~/Library/Logs/Streifen/streifen.jsonl`.
/// Schema: `{"t":"ISO8601","c":"category","e":"event","d":{...}}`
///
/// Categories: hotkey, focus, ws, layout, track, resize, config, lifecycle, error, debug
///
/// Also emits compact NSLog for Console.app realtime viewing.
final class StreifenLogger: @unchecked Sendable {
    // Main-thread only. @unchecked Sendable to match TrackedWindow pattern.
    static let shared = StreifenLogger()

    private let logDir: URL
    private let jsonlURL: URL
    private let maxSize = 5_000_000    // 5MB per file
    private let maxBackups = 2         // .1, .2 → 15MB total max

    private var fh: FileHandle?
    private var bytesWritten: Int = 0

    private let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Streifen", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        jsonlURL = logDir.appendingPathComponent("streifen.jsonl")

        rotateIfNeeded()
        openHandle()
    }

    // MARK: - Public API

    /// Structured event log (primary API)
    func log(_ cat: String, _ evt: String, _ data: [String: Any] = [:]) {
        let ts = fmt.string(from: Date())
        NSLog("[Streifen] %@.%@%@", cat, evt, data.isEmpty ? "" : " \(brief(data))")
        writeJSON(ts, cat, evt, data)
    }

    /// Unstructured message (backward compat / debug)
    func log(_ message: String) {
        let ts = fmt.string(from: Date())
        NSLog("[Streifen] %@", message)
        writeJSON(ts, "debug", "msg", ["m": message])
    }

    // MARK: - JSON Serialization

    private func writeJSON(_ t: String, _ cat: String, _ evt: String, _ data: [String: Any]) {
        var json = #"{"t":""# + t + #"","c":""# + cat + #"","e":""# + evt + #"""#
        if !data.isEmpty {
            json += #","d":{"#
            var first = true
            for (k, v) in data.sorted(by: { $0.key < $1.key }) {
                if !first { json += "," }
                json += #"""# + escapeJSON(k) + #"":"#
                json += encodeValue(v)
                first = false
            }
            json += "}"
        }
        json += "}\n"

        if let lineData = json.data(using: .utf8) {
            write(lineData)
        }
    }

    private func encodeValue(_ v: Any) -> String {
        switch v {
        case let s as String:    return #"""# + escapeJSON(s) + #"""#
        case let i as Int:       return "\(i)"
        case let i as Int32:     return "\(i)"
        case let u as UInt32:    return "\(u)"
        case let u as UInt16:    return "\(u)"
        case let d as Double:    return String(format: "%.1f", d)
        case let f as CGFloat:   return "\(Int(f))"
        case let b as Bool:      return b ? "true" : "false"
        default:
            // Catch optionals that wrapped nil
            let mirror = Mirror(reflecting: v)
            if mirror.displayStyle == .optional && mirror.children.isEmpty {
                return "null"
            }
            return #"""# + escapeJSON("\(v)") + #"""#
        }
    }

    private func escapeJSON(_ s: String) -> String {
        if !s.contains("\\") && !s.contains("\"") && !s.contains("\n") && !s.contains("\r") && !s.contains("\t") {
            return s
        }
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Compact summary for NSLog: "action=focusLeft key=4"
    private func brief(_ data: [String: Any]) -> String {
        data.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    // MARK: - File I/O

    private func write(_ data: Data) {
        if fh == nil { openHandle() }
        fh?.write(data)
        bytesWritten += data.count

        if bytesWritten > maxSize {
            fh?.closeFile()
            fh = nil
            rotateIfNeeded()
            openHandle()
        }
    }

    private func openHandle() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: jsonlURL.path) {
            fm.createFile(atPath: jsonlURL.path, contents: nil)
        }
        fh = try? FileHandle(forWritingTo: jsonlURL)
        fh?.seekToEndOfFile()
        bytesWritten = Int(fh?.offsetInFile ?? 0)
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlURL.path),
              let size = attrs[.size] as? Int, size > maxSize else { return }

        let fm = FileManager.default
        // Cascade: .2 → delete, .1 → .2, current → .1
        let path2 = jsonlURL.path + ".2"
        let path1 = jsonlURL.path + ".1"
        try? fm.removeItem(atPath: path2)
        if fm.fileExists(atPath: path1) {
            try? fm.moveItem(atPath: path1, toPath: path2)
        }
        try? fm.moveItem(atPath: jsonlURL.path, toPath: path1)
    }
}

// MARK: - Global Shorthands

/// Structured event (primary)
func slog(_ cat: String, _ evt: String, _ data: [String: Any] = [:]) {
    StreifenLogger.shared.log(cat, evt, data)
}

/// Unstructured message (backward compat)
func slog(_ message: String) {
    StreifenLogger.shared.log(message)
}
