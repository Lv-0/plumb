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

struct UpdateDownloader: Sendable {
    /// 校验 Data 的 sha256 是否等于预期十六进制串（大小写不敏感）。非法 hex 或不匹配返回 false。
    static func verifySHA256(data: Data, expectedHex: String) -> Bool {
        let digest = SHA256.hash(data: data)
        let actual = digest.compactMap { String(format: "%02x", $0) }.joined()
        return actual.lowercased() == expectedHex.lowercased()
    }

    /// 下载 url 到临时文件，返回文件 URL。
    func download(from url: URL) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: tmp)
            return tmp
        } catch {
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
    func unzip(_ zip: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", zip.path, "-d", dest.path]
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
