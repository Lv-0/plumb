import Foundation
import os

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DiagnosticLog
//
// 模块角色：轻量诊断日志（追踪自动居中/平铺管线）。
//
// 职责：
//   - 把消息写入统一日志子系统 com.comet.plumb（Console.app 可见，category autoCenter）。
//   - 当环境变量 PLUMB_LOG_FILE 设置时，同时追加写入该文件，便于离线分析问题。
//
// 设计说明：用 os_log 而非 print，避免 Release 构建里产生文件 I/O 开销；文件落盘
// 仅在显式设置环境变量时启用，是调试/取证手段，非正常运行路径。
// ─────────────────────────────────────────────────────────────────────────────

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
