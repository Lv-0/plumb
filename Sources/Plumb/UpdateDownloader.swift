import Foundation
import CryptoKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateDownloader
//
// 模块角色：下载更新包并校验完整性。
//
// 职责：
//   - 下载 zip 到临时文件。
//   - sha256 校验（防损坏/截断）。
//   - 解压到临时目录，返回其中 Plumb.app 的路径。
//
// 设计说明：下载/解压涉及网络与磁盘，端到端在手动验证里覆盖；
// sha256 校验是纯逻辑，单测覆盖。
// ─────────────────────────────────────────────────────────────────────────────

/// 下载阶段失败原因（Coordinator 据此生成用户文案）。
enum DownloadError: Error {
    case downloadFailed(underlying: Error)
    case sha256Mismatch
    case unzipFailed
    case appNotFoundInArchive
}

/// 下载进度回调。`totalBytes == -1` 表示服务器未返回 Content-Length（调用方应降级为不确定动画）。
typealias DownloadProgressHandler = @Sendable (_ bytesDownloaded: Int64, _ totalBytes: Int64) -> Void

struct UpdateDownloader: Sendable {
    /// 校验 Data 的 sha256 是否等于预期十六进制串（大小写不敏感）。非法 hex 或不匹配返回 false。
    static func verifySHA256(data: Data, expectedHex: String) -> Bool {
        let digest = SHA256.hash(data: data)
        let actual = digest.compactMap { String(format: "%02x", $0) }.joined()
        return actual.lowercased() == expectedHex.lowercased()
    }

    /// 下载 url 到临时文件，返回文件 URL。
    ///
    /// 使用 `URLSession.download(from:delegate:)`（流式落盘），相对旧的
    /// `URLSession.data(from:)`（整包缓冲进内存、无进度）有两个改进：
    ///   - **进度回调**：通过 `URLSessionDownloadDelegate.didWriteData` 上报已下载/总字节数。
    ///     `onProgress` 线程不保证；调用方需自行切回 MainActor。
    ///     `totalBytes == -1` 表示未知总长度（Content-Length 缺失）。
    ///   - **协作式取消**：该 async API 与结构化并发联动——当外层 `Task` 被 `cancel()`，
    ///     下载会被中断并抛出 `CancellationError`（Coordinator 据此区分取消与失败）。
    ///
    /// 大文件不占内存（直接落盘到临时位置，再 move 到我们自己的 tmp 路径）。
    func download(from url: URL, onProgress: DownloadProgressHandler? = nil) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        do {
            let (downloadedURL, _) = try await URLSession.shared.download(from: url, delegate: delegate)
            // downloadedURL 是 URLSession 管理的临时位置，可能很快被回收，立即移动到自有 tmp。
            if FileManager.default.fileExists(atPath: tmp.path) {
                try FileManager.default.removeItem(at: tmp)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: tmp)
            return tmp
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: tmp)
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // async URLSession.download 被 Task.cancel() 取消时，部分系统版本以 URLError(.cancelled)
            // 而非 CancellationError 抛出；统一归为取消，让 Coordinator 走静默取消分支而非"下载失败"。
            try? FileManager.default.removeItem(at: tmp)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw DownloadError.downloadFailed(underlying: error)
        }
    }

    /// 校验临时文件 sha256 与 expectedHex 匹配；不匹配抛 sha256Mismatch。
    func verify(file: URL, expectedHex: String) throws {
        let data = try Data(contentsOf: file)
        guard Self.verifySHA256(data: data, expectedHex: expectedHex) else {
            throw DownloadError.sha256Mismatch
        }
    }

    /// 解压 zip 到新临时目录，返回其中的 Plumb.app 路径。失败抛 unzipFailed / appNotFoundInArchive。
    ///
    /// 重要：必须用 `ditto -x -k` 解压（与 create_zip.sh 的 `ditto -c -k` 打包对称），而不是通用 `unzip`。
    /// .app 带有资源叉/扩展属性（如 com.apple.provenance），ditto 打包时会把它们编码进 zip。
    /// 若用通用 unzip 解压，资源叉无法正确还原 → 资源树与 ad-hoc 签名 seal 不一致 →
    /// codesign 校验 "a sealed resource is missing or invalid" → 安装后 macOS 报"应用已损坏"无法打开。
    func unzip(_ zip: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zip.path, dest.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw DownloadError.unzipFailed
        }
        guard proc.terminationStatus == 0 else { throw DownloadError.unzipFailed }
        let app = dest.appendingPathComponent("Plumb.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw DownloadError.appNotFoundInArchive
        }
        return app
    }
}

// MARK: - 下载进度代理

/// `URLSession.download(from:delegate:)` 的进度上报桥。
///
/// 把回调式 `URLSessionDownloadDelegate` 的字节写入事件转给 `onProgress` 闭包。
/// `@unchecked Sendable`：仅持有不可变 `onProgress`（其自身 `@Sendable`），跨线程访问安全。
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: DownloadProgressHandler?

    init(onProgress: DownloadProgressHandler?) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown (-1) 表示未知总长度。
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // async download(from:delegate:) 自行处理落盘，这里无需操作。
    }
}
