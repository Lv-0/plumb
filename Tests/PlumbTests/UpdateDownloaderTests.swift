import Testing
import Foundation
import CryptoKit
@testable import Plumb

@Suite("UpdateDownloader")
struct UpdateDownloaderTests {

    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }
    }

    private enum FixtureError: Error {
        case processFailed(Int32)
        case unexpectedSignatureInputs
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlumbUpdateDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFakeApp(
        in directory: URL,
        bundleIdentifier: String = UpdateDownloader.expectedBundleIdentifier,
        version: String = "9.8.7",
        includeSymbolicLink: Bool = false
    ) throws -> URL {
        let app = directory.appendingPathComponent("Plumb.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "Plumb",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)

        let executable = macOS.appendingPathComponent("Plumb")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        if includeSymbolicLink {
            try FileManager.default.createSymbolicLink(
                at: resources.appendingPathComponent("escape"),
                withDestinationURL: URL(fileURLWithPath: "/tmp/plumb-ota-escape")
            )
        }
        return app
    }

    private func makeZip(of app: URL, in directory: URL) throws -> URL {
        let zip = directory.appendingPathComponent("Plumb.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.processFailed(process.terminationStatus)
        }
        return zip
    }

    @Test("verifySHA256 passes for matching digest")
    func verifyPasses() {
        let bytes = Data("hello plumb".utf8)
        let digest = SHA256.hash(data: bytes).compactMap { String(format: "%02x", $0) }.joined()
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: digest) == true)
    }

    @Test("verifySHA256 fails for mismatched digest")
    func verifyFails() {
        let bytes = Data("hello plumb".utf8)
        let wrong = String(repeating: "0", count: 64)
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: wrong) == false)
    }

    @Test("verifySHA256 fails for malformed hex")
    func verifyMalformedHex() {
        let bytes = Data("x".utf8)
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: "nothex") == false)
    }

    @Test("verifySHA256 is case-insensitive")
    func verifyCaseInsensitive() {
        let bytes = Data("Plumb OTA".utf8)
        let digestUpper = SHA256.hash(data: bytes).compactMap { String(format: "%02X", $0) }.joined()
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: digestUpper) == true)
    }

    @Test("streaming file SHA-256 matches CryptoKit across small chunks")
    func streamingFileDigest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("archive.zip")
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        try data.write(to: file)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try UpdateDownloader.sha256Hex(of: file, chunkSize: 127) == expected)
    }

    @Test("compressed archive size validates both declared and actual bytes")
    func compressedArchiveSizeGate() throws {
        try UpdateDownloader.validateCompressedArchiveSize(
            expectedContentLength: 10,
            actualBytes: 10,
            maximumBytes: 10)
        try UpdateDownloader.validateCompressedArchiveSize(
            expectedContentLength: -1,
            actualBytes: 10,
            maximumBytes: 10)
        #expect(throws: DownloadError.self) {
            try UpdateDownloader.validateCompressedArchiveSize(
                expectedContentLength: 11,
                actualBytes: 1,
                maximumBytes: 10)
        }
        #expect(throws: DownloadError.self) {
            try UpdateDownloader.validateCompressedArchiveSize(
                expectedContentLength: -1,
                actualBytes: 11,
                maximumBytes: 10)
        }
    }

    @Test("subprocess runner enforces its timeout")
    func subprocessTimeout() {
        #expect(throws: UpdateSubprocessError.timedOut) {
            _ = try UpdateDownloader.runCancellableProcess(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 0.05,
                captureStandardOutput: false)
        }
    }

    @Test("subprocess runner bounds archive-derived captured output")
    func subprocessOutputLimit() {
        #expect(throws: UpdateSubprocessError.outputTooLarge) {
            _ = try UpdateDownloader.runCancellableProcess(
                executable: URL(fileURLWithPath: "/usr/bin/yes"),
                arguments: ["archive-entry"],
                timeout: 5,
                captureStandardOutput: true,
                maximumCapturedOutputBytes: 1_024)
        }
    }

    @Test("subprocess runner terminates promptly when its task is cancelled")
    func subprocessCancellation() async {
        let task = Task.detached {
            try UpdateDownloader.runCancellableProcess(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 30,
                captureStandardOutput: false)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let cancellationStart = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled helper must not report success")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("unexpected subprocess cancellation error: \(error)")
        }
        #expect(cancellationStart.duration(to: .now) < .seconds(2))
    }

    @Test("completed detached worker cannot hide an already-delivered parent cancellation")
    func completedWorkerCancellationRace() async throws {
        let root = try makeTemporaryDirectory()
        let producedApp = root.appendingPathComponent("Plumb.app", isDirectory: true)
        try FileManager.default.createDirectory(at: producedApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = Task.detached { () throws -> URL in
            try Task.checkCancellation()
            return producedApp
        }
        _ = try await worker.value

        let entered = AsyncGate()
        let release = AsyncGate()
        let parent = Task.detached {
            await entered.open()
            await release.wait()
            return try await UpdateDownloader.awaitWorkerResult(
                worker,
                discardingOnCancellation: { app in
                    try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
                })
        }
        await entered.wait()
        parent.cancel()
        await release.open()

        do {
            _ = try await parent.value
            Issue.record("a cancelled parent must not accept an already-completed worker result")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("unexpected cancellation-race error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: producedApp.path))
    }

    @Test("archive topology accepts the single Plumb.app tree")
    func archiveTopologyAcceptsExpectedTree() throws {
        try UpdateDownloader.validateArchiveTopology(entries: [
            "Plumb.app/",
            "Plumb.app/Contents/",
            "Plumb.app/Contents/Info.plist",
            "Plumb.app/Contents/._Info.plist",
            "Plumb.app/Contents/MacOS/Plumb",
        ])
    }

    @Test("archive topology rejects traversal extra roots and case-fold collisions")
    func archiveTopologyRejectsUnsafePaths() {
        let invalidArchives = [
            ["Plumb.app/", "Plumb.app/../escape"],
            ["Plumb.app/", "/Plumb.app/Contents/Info.plist"],
            ["Plumb.app/", "other.txt"],
            ["Plumb.app/", "Plumb.app//Contents/Info.plist"],
            ["Plumb.app/", "Plumb.app/Contents/A", "Plumb.app/contents/a"],
        ]

        for entries in invalidArchives {
            #expect(throws: DownloadError.self) {
                try UpdateDownloader.validateArchiveTopology(entries: entries)
            }
        }
    }

    @Test("central-directory descriptors reject symlinks before extraction")
    func descriptorsRejectSymbolicLinks() {
        do {
            try UpdateDownloader.validateArchiveEntryDescriptors(
                [
                    UpdateArchiveEntryDescriptor(kind: "d", uncompressedSize: 0),
                    UpdateArchiveEntryDescriptor(kind: "l", uncompressedSize: 12),
                ],
                expectedEntryCount: 2
            )
            Issue.record("expected symbolic-link rejection")
        } catch DownloadError.archiveContainsSymbolicLink {
            // Expected: this is the distinct fail-closed result used by the pre-extract gate.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("central-directory descriptors reject count mismatches special files and zip bombs")
    func descriptorsRejectAmbiguousOrOversizedArchives() {
        #expect(throws: DownloadError.self) {
            try UpdateDownloader.validateArchiveEntryDescriptors(
                [UpdateArchiveEntryDescriptor(kind: "-", uncompressedSize: 1)],
                expectedEntryCount: 2
            )
        }
        #expect(throws: DownloadError.self) {
            try UpdateDownloader.validateArchiveEntryDescriptors(
                [UpdateArchiveEntryDescriptor(kind: "p", uncompressedSize: 0)],
                expectedEntryCount: 1
            )
        }
        #expect(throws: DownloadError.self) {
            try UpdateDownloader.validateArchiveEntryDescriptors(
                [UpdateArchiveEntryDescriptor(kind: "-", uncompressedSize: 513 * 1024 * 1024)],
                expectedEntryCount: 1
            )
        }
    }

    @Test("post-extract traversal rejects every bundle symlink")
    func extractedTreeRejectsSymbolicLinks() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(in: root, includeSymbolicLink: true)

        do {
            try UpdateDownloader.validateNoSymbolicLinks(in: app)
            Issue.record("expected symbolic-link rejection")
        } catch DownloadError.archiveContainsSymbolicLink {
            // Expected defense-in-depth after extraction.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("bundle metadata validates identity version package and executable")
    func bundleMetadataValidation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(in: root)

        try UpdateDownloader.validateBundleMetadata(
            at: app,
            expectedBundleIdentifier: UpdateDownloader.expectedBundleIdentifier,
            expectedVersion: "9.8.7"
        )
        #expect(throws: DownloadError.self) {
            try UpdateDownloader.validateBundleMetadata(
                at: app,
                expectedBundleIdentifier: "com.attacker.fake",
                expectedVersion: "9.8.7"
            )
        }
        #expect(throws: DownloadError.self) {
            try UpdateDownloader.validateBundleMetadata(
                at: app,
                expectedBundleIdentifier: UpdateDownloader.expectedBundleIdentifier,
                expectedVersion: "9.8.8"
            )
        }
    }

    @Test("unzip validates the real archive shape and uses injected signature/current app")
    func unzipUsesInjectedSignaturePolicy() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(in: root)
        let zip = try makeZip(of: app, in: root)
        let currentApp = root.appendingPathComponent("CurrentPlumb.app")
        let downloader = UpdateDownloader { candidate, current in
            guard candidate.lastPathComponent == "Plumb.app", current == currentApp else {
                throw FixtureError.unexpectedSignatureInputs
            }
        }

        let extracted = try downloader.unzip(
            zip,
            expectedVersion: "9.8.7",
            currentAppURL: currentApp
        )
        defer { try? FileManager.default.removeItem(at: extracted.deletingLastPathComponent()) }
        #expect(extracted.lastPathComponent == "Plumb.app")
    }

    @Test("a symlink archive is rejected even when later signature validation would pass")
    func unzipRejectsSymbolicLinkArchive() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(in: root, includeSymbolicLink: true)
        let zip = try makeZip(of: app, in: root)
        let downloader = UpdateDownloader { _, _ in }

        do {
            _ = try downloader.unzip(
                zip,
                expectedVersion: "9.8.7",
                currentAppURL: root.appendingPathComponent("CurrentPlumb.app")
            )
            Issue.record("expected symbolic-link archive rejection")
        } catch DownloadError.archiveContainsSymbolicLink {
            // Expected from central-directory validation, before ditto is launched.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("unzip propagates signing identity mismatch from the policy gate")
    func unzipRejectsSigningIdentityMismatch() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(in: root)
        let zip = try makeZip(of: app, in: root)
        let downloader = UpdateDownloader { _, _ in
            throw DownloadError.signingIdentityMismatch(status: -1)
        }

        do {
            _ = try downloader.unzip(
                zip,
                expectedVersion: "9.8.7",
                currentAppURL: root.appendingPathComponent("CurrentPlumb.app")
            )
            Issue.record("expected signing identity mismatch")
        } catch DownloadError.signingIdentityMismatch(let status) {
            #expect(status == -1)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Security.framework rejects an unsigned candidate bundle")
    func rejectsUnsignedCandidateBundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFakeApp(in: root)

        do {
            try UpdateDownloader.validateCodeSignature(at: app, matching: app)
            Issue.record("unsigned bundle must not pass strict code-signature validation")
        } catch DownloadError.invalidCodeSignature {
            // Expected before identity comparison.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
