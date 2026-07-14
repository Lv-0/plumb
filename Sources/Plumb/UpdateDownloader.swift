import Foundation
import CryptoKit
import Security
import Darwin

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
    case invalidArchiveTopology
    case archiveContainsSymbolicLink
    case invalidBundleMetadata
    case invalidCodeSignature(status: OSStatus)
    case signingIdentityMismatch(status: OSStatus)
    case archiveTooLarge(maxBytes: Int64)
}

/// 由 `zipinfo -l` 的 central-directory 视图提取；在任何解压写入前用于拒绝
/// symlink/特殊文件和明显的解压炸弹。
struct UpdateArchiveEntryDescriptor: Equatable {
    let kind: Character
    let uncompressedSize: UInt64
}

enum UpdateSubprocessError: Error, Equatable {
    case timedOut
    case outputTooLarge
}

struct UpdateSubprocessResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
}

/// 下载进度回调。`totalBytes == -1` 表示服务器未返回 Content-Length（调用方应降级为不确定动画）。
typealias DownloadProgressHandler = @Sendable (_ bytesDownloaded: Int64, _ totalBytes: Int64) -> Void

struct UpdateDownloader: Sendable {
    typealias CodeSignatureValidator = @Sendable (_ candidateApp: URL, _ currentApp: URL) throws -> Void

    static let expectedBundleIdentifier = "com.comet.plumb"
    private static let maximumArchiveEntryCount = 10_000
    private static let maximumUncompressedArchiveSize: UInt64 = 512 * 1024 * 1024
    /// 下载阶段的压缩包硬上限。既检查服务器声明长度，也检查实际落盘字节；二者任一
    /// 超限都取消传输，避免在 central-directory 校验前先填满磁盘或耗尽内存。
    static let maximumCompressedArchiveSize: Int64 = 512 * 1024 * 1024
    private static let archiveInspectionTimeout: TimeInterval = 30
    private static let archiveExtractionTimeout: TimeInterval = 5 * 60
    /// `zipinfo` output is untrusted archive-derived text. Bound both its temporary file and
    /// the subsequent Data allocation; 16 MiB is ample for the accepted 10,000-entry product
    /// while rejecting pathological maximum-length names before they become a memory DoS.
    static let maximumInspectionOutputSize: Int64 = 16 * 1024 * 1024

    private let codeSignatureValidator: CodeSignatureValidator

    /// 签名校验器可注入，只用于对完整下载管线做确定性测试；生产默认始终执行 Security.framework
    /// 的 strict seal + 当前 designated requirement 校验。
    init(codeSignatureValidator: @escaping CodeSignatureValidator = { candidate, current in
        try UpdateDownloader.validateCodeSignature(at: candidate, matching: current)
    }) {
        self.codeSignatureValidator = codeSignatureValidator
    }

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
        let delegate = DownloadProgressDelegate(
            maximumBytes: Self.maximumCompressedArchiveSize,
            onProgress: onProgress)
        do {
            let (downloadedURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)
            let attributes = try FileManager.default.attributesOfItem(atPath: downloadedURL.path)
            let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            try Self.validateCompressedArchiveSize(
                expectedContentLength: response.expectedContentLength,
                actualBytes: actualBytes)
            // downloadedURL 是 URLSession 管理的临时位置，可能很快被回收，立即移动到自有 tmp。
            if FileManager.default.fileExists(atPath: tmp.path) {
                try FileManager.default.removeItem(at: tmp)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: tmp)
            return tmp
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: tmp)
            if delegate.exceededLimit {
                throw DownloadError.archiveTooLarge(maxBytes: Self.maximumCompressedArchiveSize)
            }
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            if delegate.exceededLimit {
                try? FileManager.default.removeItem(at: tmp)
                throw DownloadError.archiveTooLarge(maxBytes: Self.maximumCompressedArchiveSize)
            }
            // async URLSession.download 被 Task.cancel() 取消时，部分系统版本以 URLError(.cancelled)
            // 而非 CancellationError 抛出；统一归为取消，让 Coordinator 走静默取消分支而非"下载失败"。
            try? FileManager.default.removeItem(at: tmp)
            throw CancellationError()
        } catch let error as DownloadError {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw DownloadError.downloadFailed(underlying: error)
        }
    }

    /// 同时约束响应声明长度与实际落盘长度。未知声明长度用负数表示，仍由实际长度兜底。
    static func validateCompressedArchiveSize(
        expectedContentLength: Int64,
        actualBytes: Int64,
        maximumBytes: Int64 = maximumCompressedArchiveSize
    ) throws {
        guard maximumBytes > 0,
              (expectedContentLength < 0 || expectedContentLength <= maximumBytes),
              actualBytes >= 0,
              actualBytes <= maximumBytes
        else {
            throw DownloadError.archiveTooLarge(maxBytes: maximumBytes)
        }
    }

    /// 校验临时文件 sha256 与 expectedHex 匹配；不匹配抛 sha256Mismatch。
    func verify(file: URL, expectedHex: String) throws {
        let actual = try Self.sha256Hex(of: file)
        guard actual.caseInsensitiveCompare(expectedHex) == .orderedSame else {
            throw DownloadError.sha256Mismatch
        }
    }

    /// 分块计算文件 SHA-256，避免把整个更新包一次性载入内存；每个块之间响应 Task 取消。
    static func sha256Hex(of file: URL, chunkSize: Int = 1024 * 1024) throws -> String {
        guard chunkSize > 0 else { throw DownloadError.sha256Mismatch }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a local helper with cooperative Task cancellation and a hard timeout. `Process`'s
    /// blocking `waitUntilExit()` does not observe Swift cancellation; polling here lets the
    /// Cancel button terminate zipinfo/ditto promptly and prevents malformed tools/archives
    /// from pinning the update flow forever. Captured stdout goes to a file, not a Pipe, so a
    /// large central directory cannot deadlock the child on a full pipe.
    static func runCancellableProcess(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        captureStandardOutput: Bool,
        maximumCapturedOutputBytes: Int64 = maximumInspectionOutputSize
    ) throws -> UpdateSubprocessResult {
        try Task.checkCancellation()
        guard timeout >= 0,
              !captureStandardOutput || maximumCapturedOutputBytes > 0
        else { throw UpdateSubprocessError.outputTooLarge }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-process-\(UUID().uuidString).out")
        var outputHandle: FileHandle?
        if captureStandardOutput {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            outputHandle = try FileHandle(forWritingTo: outputURL)
        }
        defer {
            try? outputHandle?.close()
            if captureStandardOutput {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = outputHandle ?? FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()

        let startedAt = ProcessInfo.processInfo.systemUptime
        while process.isRunning {
            if Task.isCancelled {
                terminate(process)
                throw CancellationError()
            }
            if captureStandardOutput,
               capturedOutputSize(at: outputURL) > maximumCapturedOutputBytes {
                terminate(process)
                throw UpdateSubprocessError.outputTooLarge
            }
            if ProcessInfo.processInfo.systemUptime - startedAt >= timeout {
                terminate(process)
                throw UpdateSubprocessError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        try outputHandle?.close()
        outputHandle = nil
        if captureStandardOutput,
           capturedOutputSize(at: outputURL) > maximumCapturedOutputBytes {
            throw UpdateSubprocessError.outputTooLarge
        }
        let output = captureStandardOutput
            ? (try Data(contentsOf: outputURL))
            : Data()
        return UpdateSubprocessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: output)
    }

    private static func capturedOutputSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    /// 下载后的阻塞工作统一放到 detached worker：主线程只 await 结果，进度窗口保持可响应。
    /// 取消会传递给 worker；zipinfo/ditto 当前仍是同步子进程，但每个阶段边界都会终止后续 handoff。
    func prepareDownloadedUpdate(
        zip: URL,
        expectedSHA256: String,
        expectedVersion: String,
        currentAppURL: URL = Bundle.main.bundleURL
    ) async throws -> URL {
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            try verify(file: zip, expectedHex: expectedSHA256)
            try Task.checkCancellation()
            let app = try unzip(
                zip,
                expectedVersion: expectedVersion,
                currentAppURL: currentAppURL)
            do {
                try Task.checkCancellation()
                return app
            } catch {
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                throw error
            }
        }
        return try await Self.awaitWorkerResult(
            worker,
            discardingOnCancellation: { app in
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
            })
    }

    /// Await a detached blocking worker without allowing an already-delivered cancellation
    /// to be lost in the narrow race where the worker has completed but the awaiting task has
    /// not resumed yet. Awaiting a completed child value does not itself throw merely because
    /// the parent is cancelled, so the explicit post-await check is part of the handoff gate.
    /// A produced temporary artifact is discarded before cancellation is propagated.
    static func awaitWorkerResult<T: Sendable>(
        _ worker: Task<T, Error>,
        discardingOnCancellation discard: @escaping @Sendable (T) -> Void
    ) async throws -> T {
        try await withTaskCancellationHandler {
            let result = try await worker.value
            do {
                try Task.checkCancellation()
                return result
            } catch is CancellationError {
                discard(result)
                throw CancellationError()
            }
        } onCancel: {
            worker.cancel()
        }
    }

    /// 解压 zip 到新临时目录，校验完整的 OTA 信任边界后返回 Plumb.app。
    ///
    /// 重要：必须用 `ditto -x -k` 解压（与 create_zip.sh 的 `ditto -c -k` 打包对称），而不是通用 `unzip`。
    /// .app 带有资源叉/扩展属性（如 com.apple.provenance），ditto 打包时会把它们编码进 zip。
    /// 若用通用 unzip 解压，资源叉无法正确还原 → 资源树与 ad-hoc 签名 seal 不一致 →
    /// codesign 校验 "a sealed resource is missing or invalid" → 安装后 macOS 报"应用已损坏"无法打开。
    /// 安全策略（适配当前“稳定本地证书、无 Team ID”的现实）：
    ///   1. 解压前要求所有条目严格位于唯一顶层 `Plumb.app/` 内，拒绝绝对路径、`..`、
    ///      反斜杠与额外顶层文件；
    ///   2. 解压后再校验顶层目录，并拒绝 bundle 内任何符号链接（Plumb 当前无合法 symlink）；
    ///   3. bundle id、short/build version、package type、可执行文件必须与 manifest/产品约定一致；
    ///   4. 候选 bundle 先通过 strict codesign 校验，再必须满足当前运行 app 的 designated
    ///      requirement。对本地签名即锁定证书 leaf hash + bundle id，不依赖缺失的 Team ID。
    ///
    /// 这是刻意保守的 fail-closed 策略：从本地证书切换 Developer ID 时会被拒绝，必须在旧版
    /// 中预先发布可审计的签名轮换允许列表，不得为了迁移而跳过签名验证。
    func unzip(
        _ zip: URL,
        expectedVersion: String,
        expectedBundleIdentifier: String = Self.expectedBundleIdentifier,
        currentAppURL: URL = Bundle.main.bundleURL
    ) throws -> URL {
        try Task.checkCancellation()
        let archiveEntries = try listArchiveEntries(zip)
        try Task.checkCancellation()
        try Self.validateArchiveTopology(entries: archiveEntries)
        let archiveDescriptors = try listArchiveEntryDescriptors(zip)
        try Task.checkCancellation()
        try Self.validateArchiveEntryDescriptors(
            archiveDescriptors,
            expectedEntryCount: archiveEntries.count
        )

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var keepExtractedDirectory = false
        defer {
            if !keepExtractedDirectory {
                try? FileManager.default.removeItem(at: dest)
            }
        }
        do {
            let result = try Self.runCancellableProcess(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", zip.path, dest.path],
                timeout: Self.archiveExtractionTimeout,
                captureStandardOutput: false)
            guard result.terminationStatus == 0 else { throw DownloadError.unzipFailed }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DownloadError.unzipFailed
        }
        try Task.checkCancellation()

        let topLevelEntries = try FileManager.default.contentsOfDirectory(
            at: dest,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        guard topLevelEntries.count == 1, topLevelEntries[0].lastPathComponent == "Plumb.app" else {
            throw DownloadError.invalidArchiveTopology
        }
        let app = dest.appendingPathComponent("Plumb.app")
        let appValues = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard FileManager.default.fileExists(atPath: app.path),
              appValues.isDirectory == true,
              appValues.isSymbolicLink != true
        else {
            throw DownloadError.appNotFoundInArchive
        }

        try Self.validateNoSymbolicLinks(in: app)
        try Self.validateBundleMetadata(
            at: app,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedVersion: expectedVersion
        )
        try Task.checkCancellation()
        try codeSignatureValidator(app, currentAppURL)
        try Task.checkCancellation()

        keepExtractedDirectory = true
        return app
    }

    /// 用 zipinfo 只读取 central directory，不在拓扑未校验前解压任何条目。
    private func listArchiveEntries(_ zip: URL) throws -> [String] {
        do {
            let result = try Self.runCancellableProcess(
                executable: URL(fileURLWithPath: "/usr/bin/zipinfo"),
                arguments: ["-1", zip.path],
                timeout: Self.archiveInspectionTimeout,
                captureStandardOutput: true)
            guard result.terminationStatus == 0,
                  let raw = String(data: result.standardOutput, encoding: .utf8)
            else {
                throw DownloadError.invalidArchiveTopology
            }
            return raw.split(whereSeparator: \.isNewline).map(String.init)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DownloadError {
            throw error
        } catch {
            throw DownloadError.invalidArchiveTopology
        }
    }

    /// 读取 central directory 的 Unix mode 与未压缩大小。只接受能被 `zipinfo -l`
    /// 明确解释的条目；这样 symlink 在 `ditto` 有机会落盘/穿越前就会被拒绝。
    private func listArchiveEntryDescriptors(_ zip: URL) throws -> [UpdateArchiveEntryDescriptor] {
        do {
            let result = try Self.runCancellableProcess(
                executable: URL(fileURLWithPath: "/usr/bin/zipinfo"),
                arguments: ["-l", zip.path],
                timeout: Self.archiveInspectionTimeout,
                captureStandardOutput: true)
            guard result.terminationStatus == 0,
                  let raw = String(data: result.standardOutput, encoding: .utf8)
            else {
                throw DownloadError.invalidArchiveTopology
            }
            return raw.split(whereSeparator: \.isNewline).compactMap(Self.parseArchiveDescriptorLine)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DownloadError {
            throw error
        } catch {
            throw DownloadError.invalidArchiveTopology
        }
    }

    /// `zipinfo -l` 每个条目以 10 字符 Unix mode 开头，未压缩大小是第 4 列。
    /// 头/尾统计行不匹配该形状，返回 nil；调用方最终要求 descriptor 数与 `-1` 条目数一致。
    private static func parseArchiveDescriptorLine(_ line: Substring) -> UpdateArchiveEntryDescriptor? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4 else { return nil }
        let mode = fields[0]
        guard mode.count == 10,
              let kind = mode.first,
              "-bcdlps".contains(kind),
              mode.dropFirst().allSatisfy({ "rwxstST-".contains($0) }),
              let size = UInt64(fields[3])
        else {
            return nil
        }
        return UpdateArchiveEntryDescriptor(kind: kind, uncompressedSize: size)
    }

    /// 只允许普通文件和目录。Plumb 当前发行包不含 symlink；其它特殊 Unix 文件同样无合法用途。
    static func validateArchiveEntryDescriptors(
        _ descriptors: [UpdateArchiveEntryDescriptor],
        expectedEntryCount: Int
    ) throws {
        guard expectedEntryCount > 0, descriptors.count == expectedEntryCount else {
            throw DownloadError.invalidArchiveTopology
        }

        var totalSize: UInt64 = 0
        for descriptor in descriptors {
            if descriptor.kind == "l" {
                throw DownloadError.archiveContainsSymbolicLink
            }
            guard descriptor.kind == "-" || descriptor.kind == "d" else {
                throw DownloadError.invalidArchiveTopology
            }
            let (nextTotal, overflow) = totalSize.addingReportingOverflow(descriptor.uncompressedSize)
            guard !overflow, nextTotal <= maximumUncompressedArchiveSize else {
                throw DownloadError.invalidArchiveTopology
            }
            totalSize = nextTotal
        }
    }

    /// 解压前的纯路径校验，抵御 zip-slip 与伪造的多顶层应用。
    static func validateArchiveTopology(entries: [String]) throws {
        guard !entries.isEmpty, entries.count <= maximumArchiveEntryCount else {
            throw DownloadError.invalidArchiveTopology
        }

        var sawAppRoot = false
        var canonicalPaths = Set<String>()
        for entry in entries {
            let pathWithoutDirectorySlash = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            guard !entry.isEmpty,
                  !entry.hasPrefix("/"),
                  !entry.contains("\\"),
                  !entry.contains("//"),
                  !entry.unicodeScalars.contains(where: { $0.value == 0 })
            else {
                throw DownloadError.invalidArchiveTopology
            }

            let components = pathWithoutDirectorySlash.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let first = components.first,
                  first == "Plumb.app",
                  !components.contains("."),
                  !components.contains(".."),
                  !components.contains("")
            else {
                throw DownloadError.invalidArchiveTopology
            }

            // 默认 macOS 文件系统通常大小写不敏感；同时折叠 Unicode 组合形式，拒绝会在
            // 解压时互相覆盖的重复/碰撞路径。
            let canonicalPath = pathWithoutDirectorySlash
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard canonicalPaths.insert(canonicalPath).inserted else {
                throw DownloadError.invalidArchiveTopology
            }
            if components.count == 1 {
                sawAppRoot = true
            }
        }

        guard sawAppRoot else { throw DownloadError.invalidArchiveTopology }
    }

    /// Plumb 当前 bundle 不包含合法符号链接；全拒绝可防止解压后的路径逃逸和校验对象替换。
    static func validateNoSymbolicLinks(in root: URL) throws {
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true else {
            throw DownloadError.archiveContainsSymbolicLink
        }

        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw DownloadError.invalidArchiveTopology
        }
        for case let item as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            } catch {
                throw DownloadError.invalidArchiveTopology
            }
            if values.isSymbolicLink == true {
                throw DownloadError.archiveContainsSymbolicLink
            }
        }
        guard !enumerationFailed else {
            throw DownloadError.invalidArchiveTopology
        }
    }

    /// 不信任归档中的名称；从 bundle 本身重新读取产品身份与版本。
    static func validateBundleMetadata(
        at app: URL,
        expectedBundleIdentifier: String,
        expectedVersion: String
    ) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == expectedBundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion,
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == expectedVersion,
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executable = bundle.executableURL
        else {
            throw DownloadError.invalidBundleMetadata
        }

        let standardizedRoot = app.standardizedFileURL.resolvingSymlinksInPath().path
        let standardizedExecutable = executable.standardizedFileURL.resolvingSymlinksInPath().path
        guard standardizedExecutable.hasPrefix(standardizedRoot + "/") else {
            throw DownloadError.invalidBundleMetadata
        }
        let executableValues: URLResourceValues
        do {
            executableValues = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw DownloadError.invalidBundleMetadata
        }
        guard executableValues.isRegularFile == true, executableValues.isSymbolicLink != true else {
            throw DownloadError.invalidBundleMetadata
        }
    }

    /// 严格验证代码封印，并要求候选 app 满足当前 app 的 designated requirement。
    static func validateCodeSignature(at candidateApp: URL, matching currentApp: URL) throws {
        var candidateCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(candidateApp as CFURL, SecCSFlags(), &candidateCode)
        guard status == errSecSuccess, let candidateCode else {
            throw DownloadError.invalidCodeSignature(status: status)
        }

        let strictFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        status = SecStaticCodeCheckValidity(candidateCode, strictFlags, nil)
        guard status == errSecSuccess else {
            throw DownloadError.invalidCodeSignature(status: status)
        }

        var currentCode: SecStaticCode?
        status = SecStaticCodeCreateWithPath(currentApp as CFURL, SecCSFlags(), &currentCode)
        guard status == errSecSuccess, let currentCode else {
            throw DownloadError.signingIdentityMismatch(status: status)
        }
        status = SecStaticCodeCheckValidity(currentCode, strictFlags, nil)
        guard status == errSecSuccess else {
            throw DownloadError.signingIdentityMismatch(status: status)
        }

        var currentRequirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(currentCode, SecCSFlags(), &currentRequirement)
        guard status == errSecSuccess, let currentRequirement else {
            throw DownloadError.signingIdentityMismatch(status: status)
        }
        status = SecStaticCodeCheckValidity(candidateCode, strictFlags, currentRequirement)
        guard status == errSecSuccess else {
            throw DownloadError.signingIdentityMismatch(status: status)
        }
    }
}

// MARK: - 下载进度代理

/// `URLSession.download(from:delegate:)` 的进度上报桥。
///
/// 把回调式 `URLSessionDownloadDelegate` 的字节写入事件转给 `onProgress` 闭包。
/// `@unchecked Sendable`：仅持有不可变 `onProgress`（其自身 `@Sendable`），跨线程访问安全。
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: DownloadProgressHandler?
    private let maximumBytes: Int64
    private let stateLock = NSLock()
    private var didExceedLimit = false

    init(maximumBytes: Int64, onProgress: DownloadProgressHandler?) {
        self.maximumBytes = maximumBytes
        self.onProgress = onProgress
    }

    var exceededLimit: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return didExceedLimit
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes ||
            (totalBytesExpectedToWrite >= 0 && totalBytesExpectedToWrite > maximumBytes) {
            stateLock.lock()
            didExceedLimit = true
            stateLock.unlock()
            downloadTask.cancel()
            return
        }
        // totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown (-1) 表示未知总长度。
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // async download(from:delegate:) 自行处理落盘，这里无需操作。
    }
}
