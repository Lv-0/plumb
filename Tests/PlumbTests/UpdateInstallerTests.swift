import Testing
import Foundation
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateInstallerTests
//
// 锁死 OTA 安装器修复的关键不变量。这些不变量历史上被破坏过，导致"无法完成
// 软件更新"：
//
//   1. 生成的 AppleScript 必须是**单行**（不含 \n）。
//      多行形式能 compile 但 execute 报 -2741，是阻塞所有 OTA 的根因。
//   2. 安装源路径必须解析 symlink，且绝不能等于安装目标。
//   3. 替换必须先 staging/校验，再备份旧 app；失败必须回滚。
//   4. AppleScript 对路径里的特殊字符（引号、反斜杠）正确转义，不破坏语法。
// ─────────────────────────────────────────────────────────────────────────────

@Suite("UpdateInstallerCommand")
struct UpdateInstallerTests {
    private static let oldVersion = "1.0.0"
    private static let newVersion = "2.0.0"
    private static let trustedRequirement = "anchor apple generic"

    // MARK: AppleScript 单行不变量（回归 -2741）

    @Test("buildAppleScript produces a single-line script (regression for -2741)")
    func appleScriptIsSingleLine() {
        let shell = "rm -rf '/Applications/Plumb.app' && cp -R '/var/folders/x/Plumb.app' '/Applications/Plumb.app'"
        let apple = UpdateInstallerCommand.buildAppleScript(shellScript: shell)
        // 历史根因：多行 AppleScript 在 executeAndReturnError 报 -2741。这里钉死"单行"。
        #expect(!apple.contains("\n"))
        #expect(apple.hasPrefix("do shell script \""))
        #expect(apple.hasSuffix("\" with administrator privileges"))
    }

    @Test("buildAppleScript ends with the documented single-line form")
    func appleScriptDocumentedForm() {
        let apple = UpdateInstallerCommand.buildAppleScript(shellScript: "true")
        // 标准文档形式：单行，echo $? 在同一字符串字面量内。
        #expect(apple == "do shell script \"true ; echo $?\" with administrator privileges")
    }

    // MARK: 转义

    @Test("buildAppleScript escapes embedded double quotes")
    func escapesDoubleQuotes() {
        // 含双引号的路径必须被转义，否则破坏 AppleScript 字符串字面量。
        let apple = UpdateInstallerCommand.buildAppleScript(shellScript: "echo \"hi\"")
        #expect(apple.contains("\\\"hi\\\""))
        #expect(!apple.contains("\n"))
    }

    @Test("buildAppleScript escapes backslashes")
    func escapesBackslashes() {
        let apple = UpdateInstallerCommand.buildAppleScript(shellScript: "echo a\\b")
        #expect(apple.contains("\\\\b"))
        #expect(!apple.contains("\n"))
    }

    // MARK: shell 脚本构造

    @Test("buildShellScript stages, validates, backs up, and rolls back")
    func shellScriptShape() throws {
        let src = "/var/folders/abc/Plumb.app"
        let script = try UpdateInstallerCommand.buildShellScript(
            source: src,
            expectedVersion: Self.newVersion,
            trustedRequirement: Self.trustedRequirement,
            trustedDestinationVersion: Self.oldVersion,
            transactionID: "TEST")
        #expect(!script.contains("\n"))
        #expect(script.contains("/usr/bin/ditto"))
        #expect(script.contains("validate_app \"$stage\" \"$expected_version\""))
        #expect(script.contains("validate_app \"$dest\" \"$old_version\""))
        // codesign requires an inline requirement (`-R=<text>`). With a separate
        // argument it interprets the requirement text as a file path and every
        // privileged install fails with "invalid requirement specification".
        #expect(script.contains("-R=\"$trusted_requirement\""))
        #expect(!script.contains("-R \"$trusted_requirement\""))
        #expect(script.contains("/bin/mv \"$dest\" \"$backup\""))
        #expect(script.contains("rollback"))
        #expect(script.contains("/bin/mv \"$failed\" \"$dest\" || true"))
        #expect(script.contains("/bin/mv \"$stage\" \"$dest\" || true"))
        #expect(!script.contains("rm -rf '/Applications/Plumb.app'"))
        let collisionGuard = try #require(script.range(of: "test ! -e \"$backup\""))
        let trapInstall = try #require(script.range(of: "trap finish_on_error EXIT"))
        #expect(collisionGuard.lowerBound < trapInstall.lowerBound)
    }

    @Test("buildShellScript is valid POSIX shell syntax")
    func shellScriptParses() throws {
        let script = try UpdateInstallerCommand.buildShellScript(
            source: "/var/folders/abc/Plumb.app",
            expectedVersion: Self.newVersion,
            trustedRequirement: Self.trustedRequirement,
            trustedDestinationVersion: Self.oldVersion,
            transactionID: "PARSE")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("privileged transaction keeps old app when staging validation fails")
    func shellStagingFailureKeepsDestination() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-shell-stage-fail-\(UUID().uuidString)", isDirectory: true)
        let src = tmp.appendingPathComponent("Source.app", isDirectory: true)
        let dest = tmp.appendingPathComponent("Plumb.app", isDirectory: true)
        try Self.makeTestApp(at: src, marker: "new", bundleIdentifier: "invalid.bundle")
        try Self.makeTestApp(at: dest, marker: "old")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let script = try UpdateInstallerCommand.buildShellScript(
            source: src.path,
            expectedVersion: Self.newVersion,
            trustedRequirement: Self.trustedRequirement,
            trustedDestinationVersion: Self.oldVersion,
            destination: dest.path,
            transactionID: "STAGEFAIL")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(try Self.marker(in: dest) == "old")
        #expect(try Self.marker(in: src) == "new")
        let paths = try UpdateInstallerCommand.transactionPaths(
            destination: dest.path,
            transactionID: "STAGEFAIL")
        #expect(!FileManager.default.fileExists(atPath: paths.staging))
        #expect(!FileManager.default.fileExists(atPath: paths.backup))
        #expect(!FileManager.default.fileExists(atPath: paths.failed))
    }

    @Test("buildShellScript rejects source equal to destination")
    func shellScriptRejectsSelfReplacement() {
        do {
            _ = try UpdateInstallerCommand.buildShellScript(
                source: "/Applications/Plumb.app",
                expectedVersion: Self.newVersion,
                trustedRequirement: Self.trustedRequirement,
                trustedDestinationVersion: Self.oldVersion,
                destination: "/Applications/Plumb.app",
                transactionID: "SAME")
            Issue.record("self replacement must be rejected before shell construction")
        } catch InstallError.sourceMatchesDestination {
            // Expected.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("buildShellScript accepts custom destination")
    func shellScriptCustomDest() throws {
        let source = UpdateInstallerCommand.canonicalPath("/tmp/Src.app")
        let destination = UpdateInstallerCommand.canonicalPath("/tmp/Dst.app")
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        let script = try UpdateInstallerCommand.buildShellScript(
            source: source,
            expectedVersion: Self.newVersion,
            trustedRequirement: Self.trustedRequirement,
            trustedDestinationVersion: Self.oldVersion,
            destination: destination,
            transactionID: "CUSTOM")
        #expect(script.contains("dest='\(destination)'"))
        #expect(script.contains("stage='\(parent)/.Dst.update-CUSTOM.app'"))
        #expect(script.contains("backup='\(parent)/.Dst.backup-CUSTOM.app'"))
    }

    @Test("buildShellScript escapes single quotes in paths")
    func shellScriptEscapesSingleQuotes() throws {
        let source = UpdateInstallerCommand.canonicalPath("/tmp/O'Connor/Plumb.app")
        let script = try UpdateInstallerCommand.buildShellScript(
            source: source,
            expectedVersion: Self.newVersion,
            trustedRequirement: Self.trustedRequirement,
            trustedDestinationVersion: Self.oldVersion,
            destination: "/Applications/Plumb's Copy.app",
            transactionID: "QUOTES")
        #expect(script.contains("src=\(UpdateInstallerCommand.shellQuoted(source))"))
        #expect(script.contains("dest='/Applications/Plumb'\\''s Copy.app'"))
    }

    @Test("relaunch script shell-quotes app path")
    func relaunchScriptQuotesAppPath() {
        let script = UpdateRelaunchCommand.buildScript(
            appPath: "/tmp/O'Connor/Test App/Plumb.app",
            delaySeconds: 0)
        #expect(script == "#!/bin/bash\nsleep 0\n/usr/bin/open -n '/tmp/O'\\''Connor/Test App/Plumb.app'\n")
    }

    @Test("installer relaunch carries a signing-independent argv handoff")
    func relaunchScriptCarriesInstallerArguments() {
        let arguments = UpdateInstallerHandoff.commandLineArguments(expectedVersion: Self.newVersion)
        let script = UpdateRelaunchCommand.buildScript(
            appPath: "/tmp/New Plumb.app",
            delaySeconds: 0,
            arguments: arguments)
        #expect(script.contains("'/tmp/New Plumb.app' --args"))
        #expect(script.contains("'--plumb-install-update'"))
        #expect(script.contains("'--plumb-update-version' '2.0.0'"))
    }

    @Test("observed relaunch propagates the script exit status")
    func observedRelaunchPropagatesFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-relaunch-status-\(UUID().uuidString)", isDirectory: true)
        let script = directory.appendingPathComponent("relaunch.sh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "#!/bin/sh\nexit 7\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        do {
            try await UpdateInstallerCommand.executeRelaunchScript(at: script)
            Issue.record("a nonzero /usr/bin/open status must not be reported as success")
        } catch InstallError.relaunchFailed {
            // Expected.
        } catch {
            Issue.record("unexpected relaunch error: \(error)")
        }
    }

    @Test("argv handoff uses Bundle.main and legacy defaults cannot nominate another source")
    func installerHandoffTrustBoundary() {
        let bundle = "/tmp/download/Plumb.app"
        let destination = "/Applications/Plumb.app"
        let argv = ["Plumb"] + UpdateInstallerHandoff.commandLineArguments(
            expectedVersion: Self.newVersion)

        #expect(UpdateInstallerHandoff.resolveLaunch(
            arguments: argv,
            legacyMode: false,
            legacyPath: nil,
            bundlePath: bundle,
            bundleVersion: Self.newVersion,
            destination: destination) == UpdateInstallerHandoff(expectedVersion: Self.newVersion))

        #expect(UpdateInstallerHandoff.resolveLaunch(
            arguments: ["Plumb"],
            legacyMode: true,
            legacyPath: "/tmp/attacker/Plumb.app",
            bundlePath: bundle,
            bundleVersion: Self.newVersion,
            destination: destination) == nil)

        #expect(UpdateInstallerHandoff.resolveLaunch(
            arguments: argv,
            legacyMode: true,
            legacyPath: destination,
            bundlePath: destination,
            bundleVersion: Self.newVersion,
            destination: destination) == nil)

        #expect(UpdateInstallerHandoff.resolveLaunch(
            arguments: ["Plumb"],
            legacyMode: true,
            legacyPath: bundle,
            bundlePath: bundle,
            bundleVersion: Self.newVersion,
            destination: destination) == UpdateInstallerHandoff(expectedVersion: Self.newVersion))
    }

    @Test("destination lock retries deterministically and releases exactly once")
    func destinationLockRetryAndReleasePolicy() throws {
        final class State {
            var attempts: [UpdateInstallDestinationLock.Attempt] = [.busy, .busy, .acquired(42)]
            var uptimeValues: [TimeInterval] = [10, 10.1, 10.2]
            var sleeps: [TimeInterval] = []
            var closeCount = 0
        }
        let state = State()
        let operations = UpdateInstallDestinationLock.Operations(
            openAndAcquire: { _ in state.attempts.removeFirst() },
            closeFile: { _ in state.closeCount += 1 },
            uptime: { state.uptimeValues.removeFirst() },
            sleep: { state.sleeps.append($0) })

        let lock = try UpdateInstallDestinationLock.acquire(
            path: "/ignored/by/fake/backend",
            timeout: 1,
            pollInterval: 0.05,
            operations: operations)
        #expect(state.attempts.isEmpty)
        #expect(state.sleeps.count == 2)
        #expect(state.closeCount == 0)

        lock.release()
        lock.release()
        #expect(state.closeCount == 1)
    }

    @Test("destination lock open failure and timeout both fail closed")
    func destinationLockFailuresFailClosed() {
        final class State {
            var closeCount = 0
        }
        let openFailure = UpdateInstallDestinationLock.Operations(
            openAndAcquire: { _ in .failed },
            closeFile: { _ in Issue.record("close must not run when no descriptor was acquired") },
            uptime: { 0 },
            sleep: { _ in Issue.record("sleep must not run after open failure") })
        #expect(throws: InstallError.self) {
            _ = try UpdateInstallDestinationLock.acquire(
                timeout: 0,
                operations: openFailure)
        }

        let state = State()
        let alwaysBusy = UpdateInstallDestinationLock.Operations(
            openAndAcquire: { _ in .busy },
            closeFile: { _ in state.closeCount += 1 },
            uptime: { 100 },
            sleep: { _ in Issue.record("zero-timeout acquisition must not sleep") })
        #expect(throws: InstallError.self) {
            _ = try UpdateInstallDestinationLock.acquire(
                timeout: 0,
                operations: alwaysBusy)
        }
        #expect(state.closeCount == 0)
    }

    @Test("live destination lock serializes separate opens of one lock file")
    func liveDestinationLockContention() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-install-lock-\(UUID().uuidString)", isDirectory: true)
        let lockFile = directory.appendingPathComponent("destination.lock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try UpdateInstallDestinationLock.acquire(
            path: lockFile.path,
            timeout: 0)
        #expect(throws: InstallError.self) {
            _ = try UpdateInstallDestinationLock.acquire(
                path: lockFile.path,
                timeout: 0)
        }
        first.release()

        let afterRelease = try UpdateInstallDestinationLock.acquire(
            path: lockFile.path,
            timeout: 0)
        afterRelease.release()
    }

    @Test("temporary source cleanup only accepts argv UUID/Plumb.app shape")
    func temporarySourceCleanupPolicy() throws {
        let tempRoot = URL(fileURLWithPath: "/private/tmp/plumb-cleanup-policy", isDirectory: true)
        let uuid = "8C27A90D-5A6E-48CE-9C14-875E910F5547"
        let eligible = tempRoot
            .appendingPathComponent(uuid, isDirectory: true)
            .appendingPathComponent("Plumb.app", isDirectory: true)
        let expectedParent = eligible.deletingLastPathComponent()

        #expect(UpdateInstallerTemporarySourceCleanupPolicy.removableParentDirectory(
            bundleURL: eligible,
            temporaryDirectory: tempRoot,
            isCommandLineHandoff: true) == expectedParent)
        #expect(UpdateInstallerTemporarySourceCleanupPolicy.removableParentDirectory(
            bundleURL: eligible,
            temporaryDirectory: tempRoot,
            isCommandLineHandoff: false) == nil)
        #expect(UpdateInstallerTemporarySourceCleanupPolicy.removableParentDirectory(
            bundleURL: tempRoot.appendingPathComponent("download/Plumb.app"),
            temporaryDirectory: tempRoot,
            isCommandLineHandoff: true) == nil)
        #expect(UpdateInstallerTemporarySourceCleanupPolicy.removableParentDirectory(
            bundleURL: eligible.appendingPathComponent("Contents/Plumb.app"),
            temporaryDirectory: tempRoot,
            isCommandLineHandoff: true) == nil)
        #expect(UpdateInstallerTemporarySourceCleanupPolicy.removableParentDirectory(
            bundleURL: eligible.deletingLastPathComponent().appendingPathComponent("Other.app"),
            temporaryDirectory: tempRoot,
            isCommandLineHandoff: true) == nil)
        #expect(UpdateInstallerTemporarySourceCleanupPolicy.removableParentDirectory(
            bundleURL: URL(fileURLWithPath: "/private/tmp/\(uuid)/Plumb.app"),
            temporaryDirectory: tempRoot,
            isCommandLineHandoff: true) == nil)
    }

    @Test("privileged transaction rejects a downgrade before constructing shell")
    func shellRejectsNonIncreasingVersion() {
        #expect(throws: InstallError.self) {
            _ = try UpdateInstallerCommand.buildShellScript(
                source: "/tmp/Plumb.app",
                expectedVersion: Self.oldVersion,
                trustedRequirement: Self.trustedRequirement,
                trustedDestinationVersion: Self.newVersion,
                transactionID: "DOWNGRADE")
        }
    }

    // MARK: 源路径解析（本次修复核心：bundle path 回退）

    @Test("resolveSourcePath uses UserDefaults path when it exists on disk")
    func prefersDefaultsPath() throws {
        // 创建一个真实存在的临时路径，模拟解压后的新 app。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-test-src-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: tmp.path,
            bundlePathFallback: "/some/other/path.app")
        #expect(resolved == UpdateInstallerCommand.canonicalPath(tmp.path))
    }

    @Test("resolveSourcePath falls back to bundle path when UserDefaults path is nil")
    func fallsBackToBundlePath() throws {
        // 模拟新 app 自启动进安装器：标志未写（或丢失），但 Bundle.main 存在。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-test-src-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: nil,
            bundlePathFallback: tmp.path)
        #expect(resolved == UpdateInstallerCommand.canonicalPath(tmp.path))
    }

    @Test("resolveSourcePath falls back to bundle path when UserDefaults path is missing on disk")
    func fallsBackToBundlePathWhenDefaultsStale() throws {
        // UserDefaults 里残留的临时路径已被系统清理（/var/folders 定期回收）。
        // 此时必须回退到 bundle path，否则安装器报 missingAppPath 卡死。
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-test-src-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: "/var/folders/STALE/Plumb.app",   // 不存在
            bundlePathFallback: bundle.path)
        #expect(resolved == UpdateInstallerCommand.canonicalPath(bundle.path))
    }

    @Test("resolveSourcePath returns nil when neither path exists")
    func returnsNilWhenBothMissing() {
        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: "/nonexistent/a.app",
            bundlePathFallback: "/nonexistent/b.app")
        #expect(resolved == nil)
    }

    @Test("resolveSourcePath ignores empty UserDefaults path")
    func ignoresEmptyDefaults() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-test-src-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: "",
            bundlePathFallback: bundle.path)
        #expect(resolved == UpdateInstallerCommand.canonicalPath(bundle.path))
    }

    @Test("resolveSourcePath rejects installed app as its own update source")
    func rejectsSourceEqualToDestination() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-same-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: nil,
            bundlePathFallback: tmp.path,
            destination: tmp.path)
        #expect(resolved == nil)
    }

    @Test("resolveSourcePath resolves symlinks before rejecting self replacement")
    func rejectsSymlinkToDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-symlink-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Plumb.app", isDirectory: true)
        let symlink = root.appendingPathComponent("Downloaded.app")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: destination)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: symlink.path,
            bundlePathFallback: destination.path,
            destination: destination.path)
        #expect(resolved == nil)
    }

    // MARK: 端到端：源解析 → shell → AppleScript

    @Test("end-to-end: bundle-path fallback yields a valid single-line privileged install")
    func endToEndBundleFallback() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-test-src-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        // 模拟新 app 自启动：无 UserDefaults 标志。
        let src = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: nil, bundlePathFallback: bundle.path)
        #expect(src != nil)
        let shell = try UpdateInstallerCommand.buildShellScript(
            source: src!,
            expectedVersion: Self.newVersion,
            trustedRequirement: Self.trustedRequirement,
            trustedDestinationVersion: Self.oldVersion,
            transactionID: "E2E")
        let apple = UpdateInstallerCommand.buildAppleScript(shellScript: shell)

        // 不变量：单行、合法形式。
        #expect(!apple.contains("\n"))
        #expect(apple.contains("/usr/bin/ditto"))
        #expect(apple.contains("with administrator privileges"))
        #expect(apple.contains(UpdateInstallerCommand.canonicalPath(bundle.path)))
    }

    // MARK: canReplaceWithoutPrivileges（双路径核心：与 Sparkle 无密码启发式一致）
    //
    // 决定安装器走"无提权快路径"还是"AppleScript 提权路径"。
    // 逻辑（纯函数，依赖注入 owner/writable/uid，可单测全部分支）：
    //   - 目标存在：仅当目标 owner == 当前 uid 才可无提权替换；
    //   - 目标不存在：仅当父目录当前 uid 可写才可无提权创建。
    // 用注入形式避免在单测里构造 root-owned 真实文件（单测进程非 root）。

    @Test("canReplaceWithoutPrivileges: admin-owned target → true (fast path)")
    func canReplaceAdminOwnedTarget() {
        // 目标 .app 存在，owner 是当前用户（admin 组）→ 尝试无提权事务替换。
        let r = UpdateInstallerCommand.canReplaceWithoutPrivileges(
            destination: "/Applications/Plumb.app",
            destinationExists: true,
            destinationOwnerUID: 501,
            parentDirectoryWritable: true,
            currentUID: 501)
        #expect(r == true)
    }

    @Test("canReplaceWithoutPrivileges: root-owned target → false (needs privileges)")
    func canReplaceRootOwnedTarget() {
        // 目标 .app 存在但 owner=root(0)，当前用户=501 → 必须提权（当前机器的真实状态）。
        let r = UpdateInstallerCommand.canReplaceWithoutPrivileges(
            destination: "/Applications/Plumb.app",
            destinationExists: true,
            destinationOwnerUID: 0,
            parentDirectoryWritable: true,
            currentUID: 501)
        #expect(r == false)
    }

    @Test("canReplaceWithoutPrivileges: missing target + writable parent → true")
    func canReplaceMissingTargetWritableParent() {
        // 目标不存在（新装），父目录 /Applications 当前用户可写 → 直接 mv，无需提权。
        let r = UpdateInstallerCommand.canReplaceWithoutPrivileges(
            destination: "/Applications/Plumb.app",
            destinationExists: false,
            destinationOwnerUID: 0,
            parentDirectoryWritable: true,
            currentUID: 501)
        #expect(r == true)
    }

    @Test("canReplaceWithoutPrivileges: missing target + non-writable parent → false")
    func canReplaceMissingTargetNonWritableParent() {
        // 目标不存在且父目录不可写（如受限的 /Applications）→ 需提权。
        let r = UpdateInstallerCommand.canReplaceWithoutPrivileges(
            destination: "/Applications/Plumb.app",
            destinationExists: false,
            destinationOwnerUID: 0,
            parentDirectoryWritable: false,
            currentUID: 501)
        #expect(r == false)
    }

    @Test("canReplaceWithoutPrivileges: admin-owned but uid mismatch → false")
    func canReplaceOwnedByOtherUser() {
        // 目标存在，owner 是别的非 root 用户（如 502），当前用户 501 无权删 → 需提权。
        let r = UpdateInstallerCommand.canReplaceWithoutPrivileges(
            destination: "/Applications/Plumb.app",
            destinationExists: true,
            destinationOwnerUID: 502,
            parentDirectoryWritable: true,
            currentUID: 501)
        #expect(r == false)
    }

    // MARK: 快路径替换语义（同目录事务，纯 FileManager，无 shell 注入面）
    //
    // 快路径与提权路径的等价性：都先复制 source 到同目录 staging，校验后再把旧
    // destination 备份，并以 rename 切换；失败时恢复旧版本。

    @Test("replaceWithoutPrivileges: missing destination → stage copy then rename into place")
    func replaceMissingDestination() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-replace-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // source: 一个假的 .app 目录（含一个文件，模拟 bundle 内容）
        let src = tmp.appendingPathComponent("Source.app", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "binary".write(to: src.appendingPathComponent("Plumb"), atomically: true, encoding: .utf8)

        let dest = tmp.appendingPathComponent("Plumb.app")
        #expect(!FileManager.default.fileExists(atPath: dest.path))

        try UpdateInstallerCommand.replaceWithoutPrivileges(
            source: src.path,
            destination: dest.path,
            transactionID: "MISSING",
            validator: { _ in })

        // 替换后 dest 存在，且内容来自 source。
        #expect(FileManager.default.fileExists(atPath: dest.path))
        let moved = try String(contentsOf: dest.appendingPathComponent("Plumb"), encoding: .utf8)
        #expect(moved == "binary")
        // 安装器正在从 source 运行，事务只能 copy，不能把活体 bundle move 走。
        #expect(FileManager.default.fileExists(atPath: src.path))
    }

    @Test("replaceWithoutPrivileges: existing destination → backup old then rename new")
    func replaceExistingDestination() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-replace-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // source（新版本内容）
        let src = tmp.appendingPathComponent("Source.app", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "new-binary".write(to: src.appendingPathComponent("Plumb"), atomically: true, encoding: .utf8)

        // destination（旧版本，存在且内容不同）
        let dest = tmp.appendingPathComponent("Plumb.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "old-binary".write(to: dest.appendingPathComponent("Plumb"), atomically: true, encoding: .utf8)

        try UpdateInstallerCommand.replaceWithoutPrivileges(
            source: src.path,
            destination: dest.path,
            transactionID: "EXISTING",
            validator: { _ in })

        // 替换后 dest 内容是新版本。
        let moved = try String(contentsOf: dest.appendingPathComponent("Plumb"), encoding: .utf8)
        #expect(moved == "new-binary")
        #expect(FileManager.default.fileExists(atPath: src.path))
        let paths = try UpdateInstallerCommand.transactionPaths(
            destination: dest.path,
            transactionID: "EXISTING")
        #expect(!FileManager.default.fileExists(atPath: paths.staging))
        #expect(!FileManager.default.fileExists(atPath: paths.backup))
        #expect(!FileManager.default.fileExists(atPath: paths.failed))
    }

    @Test("replaceWithoutPrivileges rejects source equal to destination before any mutation")
    func replacementRejectsSamePath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-same-replace-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let marker = tmp.appendingPathComponent("marker")
        try "old".write(to: marker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            try UpdateInstallerCommand.replaceWithoutPrivileges(
                source: tmp.path,
                destination: tmp.path,
                transactionID: "SAME",
                validator: { _ in })
            Issue.record("self replacement must throw")
        } catch InstallError.sourceMatchesDestination {
            // Expected.
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "old")
    }

    @Test("staging validation failure leaves the old app untouched")
    func validationFailurePreservesDestination() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-validation-\(UUID().uuidString)", isDirectory: true)
        let src = tmp.appendingPathComponent("Source.app", isDirectory: true)
        let dest = tmp.appendingPathComponent("Plumb.app", isDirectory: true)
        try Self.makeTestApp(at: src, marker: "new")
        try Self.makeTestApp(at: dest, marker: "old")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            try UpdateInstallerCommand.replaceWithoutPrivileges(
                source: src.path,
                destination: dest.path,
                transactionID: "BADSTAGE",
                validator: { _ in
                    throw InstallError.invalidAppBundle(reason: "injected")
                })
            Issue.record("invalid staging app must fail")
        } catch InstallError.invalidAppBundle {
            // Expected.
        }

        #expect(try Self.marker(in: dest) == "old")
        #expect(try Self.marker(in: src) == "new")
    }

    @Test("move failure after backup restores the old app")
    func moveFailureRollsBack() throws {
        final class MoveCounter {
            var count = 0
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-rollback-\(UUID().uuidString)", isDirectory: true)
        let src = tmp.appendingPathComponent("Source.app", isDirectory: true)
        let dest = tmp.appendingPathComponent("Plumb.app", isDirectory: true)
        try Self.makeTestApp(at: src, marker: "new")
        try Self.makeTestApp(at: dest, marker: "old")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let counter = MoveCounter()
        var operations = UpdateInstallerCommand.InstallFileOperations.live
        operations.moveItem = { from, to in
            counter.count += 1
            // 1 = destination -> backup; fail 2 = staging -> destination.
            if counter.count == 2 {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.moveItem(at: from, to: to)
        }

        do {
            try UpdateInstallerCommand.replaceWithoutPrivileges(
                source: src.path,
                destination: dest.path,
                transactionID: "ROLLBACK",
                operations: operations,
                validator: { _ in })
            Issue.record("injected move failure must throw")
        } catch {
            // Expected injected failure after the original app was backed up.
        }

        #expect(try Self.marker(in: dest) == "old")
        #expect(try Self.marker(in: src) == "new")
        let paths = try UpdateInstallerCommand.transactionPaths(
            destination: dest.path,
            transactionID: "ROLLBACK")
        #expect(!FileManager.default.fileExists(atPath: paths.staging))
        #expect(!FileManager.default.fileExists(atPath: paths.backup))
    }

    @Test("destination validation failure restores the old app")
    func destinationValidationFailureRollsBack() throws {
        final class ValidationCounter {
            var count = 0
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-final-validation-\(UUID().uuidString)", isDirectory: true)
        let src = tmp.appendingPathComponent("Source.app", isDirectory: true)
        let dest = tmp.appendingPathComponent("Plumb.app", isDirectory: true)
        try Self.makeTestApp(at: src, marker: "new")
        try Self.makeTestApp(at: dest, marker: "old")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let counter = ValidationCounter()
        do {
            try UpdateInstallerCommand.replaceWithoutPrivileges(
                source: src.path,
                destination: dest.path,
                transactionID: "FINALBAD",
                validator: { _ in
                    counter.count += 1
                    if counter.count == 2 {
                        throw InstallError.invalidAppBundle(reason: "injected final validation")
                    }
                })
            Issue.record("invalid final destination must fail")
        } catch InstallError.invalidAppBundle {
            // Expected after staging passed and the destination was replaced.
        }

        #expect(counter.count == 2)
        #expect(try Self.marker(in: dest) == "old")
        #expect(try Self.marker(in: src) == "new")
    }

    @Test("rollback failure preserves the old app backup for recovery")
    func rollbackFailurePreservesBackup() throws {
        final class MoveCounter {
            var count = 0
        }
        final class ValidationCounter {
            var count = 0
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-rollback-fail-\(UUID().uuidString)", isDirectory: true)
        let src = tmp.appendingPathComponent("Source.app", isDirectory: true)
        let dest = tmp.appendingPathComponent("Plumb.app", isDirectory: true)
        try Self.makeTestApp(at: src, marker: "new")
        try Self.makeTestApp(at: dest, marker: "old")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let counter = MoveCounter()
        let validationCounter = ValidationCounter()
        var operations = UpdateInstallerCommand.InstallFileOperations.live
        operations.moveItem = { from, to in
            counter.count += 1
            // 1 backs up old; 2 installs new; 3 moves invalid new aside;
            // 4 fails old-backup restoration; 5 puts new back at destination.
            if counter.count == 4 {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.moveItem(at: from, to: to)
        }

        let paths = try UpdateInstallerCommand.transactionPaths(
            destination: dest.path,
            transactionID: "ROLLBACKFAIL")
        do {
            try UpdateInstallerCommand.replaceWithoutPrivileges(
                source: src.path,
                destination: dest.path,
                transactionID: "ROLLBACKFAIL",
                operations: operations,
                validator: { _ in
                    validationCounter.count += 1
                    if validationCounter.count == 2 {
                        throw InstallError.invalidAppBundle(reason: "injected final validation")
                    }
                })
            Issue.record("failed rollback must throw a recovery-path error")
        } catch InstallError.rollbackFailed(let backupPath) {
            #expect(backupPath == paths.backup)
        }

        #expect(counter.count == 5)
        #expect(try Self.marker(in: dest) == "new")
        #expect(try Self.marker(in: URL(fileURLWithPath: paths.backup)) == "old")
        #expect(try Self.marker(in: src) == "new")
        #expect(!FileManager.default.fileExists(atPath: paths.failed))
    }

    @Test("bundle validation checks identifier, executable, and signature hook")
    func validatesBundleStructureAndSignature() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-validate-\(UUID().uuidString)", isDirectory: true)
        let app = tmp.appendingPathComponent("Plumb.app", isDirectory: true)
        try Self.makeTestApp(at: app, marker: "new")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var checkedPath: String?
        try UpdateInstallerCommand.validateAppBundle(at: app.path) { path in
            checkedPath = path
            return true
        }
        #expect(checkedPath == UpdateInstallerCommand.canonicalPath(app.path))

        do {
            try UpdateInstallerCommand.validateAppBundle(at: app.path) { _ in false }
            Issue.record("signature failure must reject the staged app")
        } catch InstallError.invalidAppBundle {
            // Expected.
        }
    }

    @Test("bundle validation requires exact expected version and a strict upgrade")
    func validatesExpectedAndIncreasingVersion() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-version-\(UUID().uuidString)", isDirectory: true)
        let app = tmp.appendingPathComponent("Plumb.app", isDirectory: true)
        try Self.makeTestApp(at: app, marker: "new", version: Self.newVersion)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try UpdateInstallerCommand.validateAppBundle(
            at: app.path,
            expectedVersion: Self.newVersion,
            versionMustBeNewerThan: AppVersion(parsing: Self.oldVersion),
            signatureVerifier: { _ in true })

        #expect(throws: InstallError.self) {
            try UpdateInstallerCommand.validateAppBundle(
                at: app.path,
                expectedVersion: "3.0.0",
                versionMustBeNewerThan: AppVersion(parsing: Self.oldVersion),
                signatureVerifier: { _ in true })
        }
        #expect(throws: InstallError.self) {
            try UpdateInstallerCommand.validateAppBundle(
                at: app.path,
                expectedVersion: Self.newVersion,
                versionMustBeNewerThan: AppVersion(parsing: "3.0.0"),
                signatureVerifier: { _ in true })
        }
    }

    private static func makeTestApp(
        at appURL: URL,
        marker: String,
        bundleIdentifier: String = UpdateInstallerCommand.expectedBundleIdentifier,
        version: String = newVersion
    ) throws {
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/Plumb")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try marker.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "Plumb",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0)
        try data.write(
            to: appURL.appendingPathComponent("Contents/Info.plist"),
            options: .atomic)
    }

    private static func marker(in appURL: URL) throws -> String {
        try String(
            contentsOf: appURL.appendingPathComponent("Contents/MacOS/Plumb"),
            encoding: .utf8)
    }
}
