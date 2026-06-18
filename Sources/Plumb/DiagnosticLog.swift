import Foundation
import os

/// Lightweight diagnostic logger used to trace the auto-centering pipeline.
/// Writes to the unified logging subsystem `com.comet.plumb` (visible in Console.app)
/// and, when the env var `PLUMB_LOG_FILE` is set, also appends to that file.
enum DiagnosticLog {
    private static let log = OSLog(subsystem: "com.comet.plumb", category: "autoCenter")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func debug(_ message: String) {
        os_log("%{public}@", log: log, type: .debug, message)
        if let path = ProcessInfo.processInfo.environment["PLUMB_LOG_FILE"] {
            let line = "\(dateFormatter.string(from: Date())) \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: path) {
                    if let h = FileHandle(forWritingAtPath: path) {
                        h.seekToEndOfFile()
                        h.write(data)
                        h.closeFile()
                    }
                } else {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }
}
