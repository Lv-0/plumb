import Foundation
import AppKit
import Security
import Darwin

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateInstaller
//
// 模块角色：安装器模式入口（installerMode 标志触发）。
//
// 职责：
//   - 极简 NSWindow 显示进度。
//   - 通过 NSAppleScript 的 `do shell script ... with administrator privileges` 提权执行
//     同目录 staging + 校验 + 备份替换 /Applications/Plumb.app（弹系统密码框一次）。
//   - 清零 installerMode 标志，以 Launch Services 启动新版本。
//
// 设计说明：主 app 退出后由本进程完成替换，避免"运行中二进制被覆盖"。
// 替换前 newApp 已通过 sha256 校验（由 Coordinator 保证）；安装器仍会独立校验
// bundle id、主可执行文件与代码签名，避免仅凭残留路径替换目标。
// 用 AppleScript 的 administrator privileges 而非已废弃的 AuthorizationExecuteWithPrivileges：
// 同样弹系统密码框，但 API 稳定、可正确回传子进程 exit code。
// 命令路径来自主 app 校验后的固定临时位置，不接受用户输入，提权最小化。
// ─────────────────────────────────────────────────────────────────────────────

enum InstallError: Error {
    case missingAppPath
    case sourceMatchesDestination
    case invalidAppBundle(reason: String)
    case rollbackFailed(backupPath: String)
    case authorizationDenied       // 用户取消密码框
    case replaceFailed(status: Int)
    case unprivilegedReplaceFailed // 快路径无提权替换失败（调用方据此回退提权路径或报错）
    case installLockUnavailable    // 另一安装器正在替换同一目标，或锁无法安全建立
    case relaunchFailed
}

/// 两个 Plumb 进程可能同时完成下载（例如用户运行了两份 app，或重复
/// `open -n` 临时 bundle）。事务 UUID 只能隔离 staging 名称，不能保护共享的
/// `/Applications/Plumb.app`。此锁因此必须跨进程，并覆盖“捕获旧版信任锚点 →
/// 快/提权事务 → 发起新版重开”的整个关键段。
///
/// 锁文件刻意保留在全局 sticky temp 目录，不在 release 时 unlink：删除并重建
/// 会产生两个 inode，反而允许两个进程同时持有“同名”锁。`flock` 在进程
/// 崩溃时由内核自动释放，因此残留空文件不是死锁。
final class UpdateInstallDestinationLock {
    static let sharedLockPath = "/private/tmp/com.comet.plumb.update-install.lock"
    static let defaultTimeout: TimeInterval = 5
    static let defaultPollInterval: TimeInterval = 0.05

    enum Attempt {
        case acquired(Int32)
        case busy
        case failed
    }

    /// 全注入后端让忙锁/超时/打开失败可以在单测中零 sleep 、确定性复现。
    struct Operations: @unchecked Sendable {
        var openAndAcquire: (String) -> Attempt
        var closeFile: (Int32) -> Void
        var uptime: () -> TimeInterval
        var sleep: (TimeInterval) -> Void

        static let live = Operations(
            openAndAcquire: { path in
                UpdateInstallDestinationLock.openValidatedAndLockedFile(path)
            },
            closeFile: { descriptor in
                _ = Darwin.close(descriptor)
            },
            uptime: { ProcessInfo.processInfo.systemUptime },
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    private var descriptor: Int32
    private let operations: Operations

    private init(descriptor: Int32, operations: Operations) {
        self.descriptor = descriptor
        self.operations = operations
    }

    static func acquire(
        path: String = sharedLockPath,
        timeout: TimeInterval = defaultTimeout,
        pollInterval: TimeInterval = defaultPollInterval,
        operations: Operations = .live
    ) throws -> UpdateInstallDestinationLock {
        guard timeout >= 0, pollInterval > 0 else {
            throw InstallError.installLockUnavailable
        }

        let startedAt = operations.uptime()
        while true {
            switch operations.openAndAcquire(path) {
            case .acquired(let descriptor):
                return UpdateInstallDestinationLock(
                    descriptor: descriptor,
                    operations: operations)
            case .failed:
                throw InstallError.installLockUnavailable
            case .busy:
                let elapsed = max(0, operations.uptime() - startedAt)
                guard elapsed < timeout else {
                    throw InstallError.installLockUnavailable
                }
                operations.sleep(min(pollInterval, timeout - elapsed))
            }
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        let ownedDescriptor = descriptor
        descriptor = -1
        // O_EXLOCK 的所有权绑定这个 open file description，close 即原子释放。
        operations.closeFile(ownedDescriptor)
    }

    deinit {
        release()
    }

    /// O_NOFOLLOW + regular-file/single-link 检查避免把攻击者预置的 symlink/hardlink
    /// 当成锁文件。任何异常都返回 -1，上层 fail closed，绝不继续替换。
    private static func openValidatedAndLockedFile(_ path: String) -> Attempt {
        // O_EXLOCK 在 open 时原子取得 BSD advisory lock；不存在“打开成功但
        // 尚未加锁”的争用窗口。O_NONBLOCK 让上层用有界轮询实现超时。
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
            mode_t(0o666))
        guard descriptor >= 0 else {
            return errno == EWOULDBLOCK || errno == EAGAIN ? .busy : .failed
        }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1
        else {
            _ = Darwin.close(descriptor)
            return .failed
        }

        // 首个创建者可能受 umask 影响。锁不包含数据，设为 0666 使不同本地
        // 用户启动的安装器也会争用同一目标锁；sticky /private/tmp 仍阻止其他
        // 用户 unlink 该文件。非 owner 不能 chmod，但既然 O_RDWR 已成功就无需失败。
        if info.st_uid == geteuid() {
            _ = Darwin.fchmod(descriptor, mode_t(0o666))
        }
        return .acquired(descriptor)
    }
}

/// 成功安装后只允许删除 downloader 生成的
/// `<system temp>/<UUID>/Plumb.app` 父目录。legacy defaults handoff 可以指向用户保留
/// 的任意 bundle，即使路径碰巧相似也永不自动删除。
enum UpdateInstallerTemporarySourceCleanupPolicy {
    static func removableParentDirectory(
        bundleURL: URL,
        temporaryDirectory: URL,
        isCommandLineHandoff: Bool
    ) -> URL? {
        guard isCommandLineHandoff else { return nil }
        let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let tempRoot = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard bundle.lastPathComponent == "Plumb.app" else { return nil }

        let parent = bundle.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().path == tempRoot.path,
              UUID(uuidString: parent.lastPathComponent) != nil
        else { return nil }
        return parent
    }
}

/// 签名无关的安装器启动协议。新 app 通过 LaunchServices argv 接收期望版本，不再依赖
/// 可能随签名身份变化而不可见的 UserDefaults 域；安装源永远是正在运行的 Bundle.main。
struct UpdateInstallerHandoff: Equatable {
    static let modeArgument = "--plumb-install-update"
    static let versionArgument = "--plumb-update-version"

    let expectedVersion: String

    static func commandLineArguments(expectedVersion: String) -> [String] {
        [modeArgument, versionArgument, expectedVersion]
    }

    static func parse(arguments: [String]) -> UpdateInstallerHandoff? {
        guard arguments.filter({ $0 == modeArgument }).count == 1,
              arguments.filter({ $0 == versionArgument }).count == 1,
              let versionIndex = arguments.firstIndex(of: versionArgument),
              arguments.indices.contains(versionIndex + 1)
        else { return nil }
        let version = arguments[versionIndex + 1]
        guard AppVersion(parsing: version) != nil else { return nil }
        return UpdateInstallerHandoff(expectedVersion: version)
    }

    /// 解析新 argv handoff；旧 UserDefaults 仅在“记录路径精确等于当前运行 bundle、且该
    /// bundle 不是安装目标”时兼容。它不能再把任意可写路径提升为安装信任源。
    static func resolveLaunch(
        arguments: [String],
        legacyMode: Bool,
        legacyPath: String?,
        bundlePath: String,
        bundleVersion: String?,
        destination: String = UpdateInstallerCommand.destination
    ) -> UpdateInstallerHandoff? {
        let bundle = UpdateInstallerCommand.canonicalPath(bundlePath)
        let installed = UpdateInstallerCommand.canonicalPath(destination)
        guard bundle != installed else { return nil }

        if let handoff = parse(arguments: arguments) {
            return handoff
        }

        guard legacyMode,
              let legacyPath,
              UpdateInstallerCommand.canonicalPath(legacyPath) == bundle,
              let bundleVersion,
              AppVersion(parsing: bundleVersion) != nil
        else { return nil }
        return UpdateInstallerHandoff(expectedVersion: bundleVersion)
    }
}

/// 从当前受信任安装目标捕获的不可变更新锚点。后续 source、staging、最终 destination
/// 都必须满足同一 designated requirement，且新版本必须严格高于 installedVersion。
struct UpdateInstallTrust: Equatable {
    let designatedRequirement: String
    let installedVersion: String
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateInstallerCommand (pure, testable)
//
// 模块角色：安装器命令的纯逻辑构造（无 IO、无 AppKit），把"源路径解析 →
// shell 脚本 → 单行 AppleScript"这条链抽出来单测。
//
// 为什么独立：历史 bug（-2741 AppleScript 语法错误）和"装错源"问题都
// 发生在这条链里。把它从 NSApplicationDelegate 里剥离后，可以用 swift-testing
// 精确断言"生成的 AppleScript 永远是单行"和"源路径优先用新 app 自身路径"，
// 防止回归。
// ─────────────────────────────────────────────────────────────────────────────

/// 安装命令构造器。它不触网、不弹窗；路径解析和 bundle 校验会读取本地文件系统。
enum UpdateInstallerCommand {
    /// 安装目标：固定为 /Applications/Plumb.app。
    static let destination = "/Applications/Plumb.app"
    static let expectedBundleIdentifier = "com.comet.plumb"

    struct TransactionPaths: Equatable {
        let staging: String
        let backup: String
        let failed: String
    }

    /// FileManager operations are injectable so rollback behavior can be exercised without
    /// touching /Applications or relying on a real disk failure.
    struct InstallFileOperations: @unchecked Sendable {
        var fileExists: (String) -> Bool
        var copyItem: (URL, URL) throws -> Void
        var moveItem: (URL, URL) throws -> Void
        var removeItem: (URL) throws -> Void

        static let live = InstallFileOperations(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) }
        )
    }

    /// 解析待复制的源 .app 路径。
    ///
    /// 解析顺序：
    ///   1. UserDefaults 里记录的路径（旧流程：coordinator 写入的临时解压路径）；
    ///      若该路径在磁盘上存在则采用。
    ///   2. 否则回退到 `bundlePathFallback`（生产里传 Bundle.main.bundlePath）。
    ///
    /// 回退到 bundlePath 是本次修复的关键：coordinator 现在直接启动**新** app
    /// 进入安装器模式（见 UpdateCoordinator.relaunchIntoInstaller），所以安装器
    /// 进程本身就是新 app —— 它自己的 bundle 路径就是要拷贝的源。即便
    /// UserDefaults 标志因任何原因丢失（临时目录被清理、domain 解析差异），
    /// 安装器仍能凭自身路径完成替换，不再卡死。
    ///
    /// 仍保留 UserDefaults 优先级是为了向后兼容：任何已经写入标志的进行中流程
    /// 不受影响。
    static func resolveSourcePath(
        defaultsPath: String?,
        bundlePathFallback: String,
        destination: String = destination
    ) -> String? {
        let canonicalDestination = canonicalPath(destination)
        let candidates = [defaultsPath, bundlePathFallback]
        for rawCandidate in candidates {
            guard let rawCandidate, !rawCandidate.isEmpty else { continue }
            let candidate = canonicalPath(rawCandidate)
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  URL(fileURLWithPath: candidate).pathExtension.lowercased() == "app",
                  candidate != canonicalDestination
            else { continue }
            return candidate
        }
        return nil
    }

    static func canonicalPath(_ rawPath: String) -> String {
        URL(fileURLWithPath: rawPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    static func transactionPaths(
        destination: String,
        transactionID: String
    ) throws -> TransactionPaths {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !transactionID.isEmpty,
              transactionID.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            throw InstallError.invalidAppBundle(reason: "invalid transaction id")
        }
        let destinationURL = URL(fileURLWithPath: canonicalPath(destination))
        let parent = destinationURL.deletingLastPathComponent()
        let base = destinationURL.deletingPathExtension().lastPathComponent
        return TransactionPaths(
            staging: parent.appendingPathComponent(".\(base).update-\(transactionID).app").path,
            backup: parent.appendingPathComponent(".\(base).backup-\(transactionID).app").path,
            failed: parent.appendingPathComponent(".\(base).failed-\(transactionID).app").path
        )
    }

    /// Build the privileged transaction as one shell line. The old destination is first moved
    /// to a same-directory backup and is restored by the EXIT trap on every later failure.
    static func buildShellScript(
        source: String,
        expectedVersion: String,
        trustedRequirement: String,
        trustedDestinationVersion: String,
        destination: String = destination,
        transactionID: String = UUID().uuidString
    ) throws -> String {
        let canonicalSource = canonicalPath(source)
        let canonicalDestination = canonicalPath(destination)
        guard canonicalSource != canonicalDestination else {
            throw InstallError.sourceMatchesDestination
        }
        guard let newVersion = AppVersion(parsing: expectedVersion),
              let oldVersion = AppVersion(parsing: trustedDestinationVersion),
              newVersion > oldVersion,
              !trustedRequirement.isEmpty
        else {
            throw InstallError.invalidAppBundle(reason: "invalid or non-increasing update trust metadata")
        }
        let paths = try transactionPaths(
            destination: canonicalDestination,
            transactionID: transactionID
        )
        let sourceQ = shellQuoted(canonicalSource)
        let destinationQ = shellQuoted(canonicalDestination)
        let stagingQ = shellQuoted(paths.staging)
        let backupQ = shellQuoted(paths.backup)
        let failedQ = shellQuoted(paths.failed)
        let stageLeafQ = shellQuoted(URL(fileURLWithPath: paths.staging).lastPathComponent)
        let bundleIDQ = shellQuoted(expectedBundleIdentifier)
        let expectedVersionQ = shellQuoted(expectedVersion)
        let oldVersionQ = shellQuoted(trustedDestinationVersion)
        let requirementQ = shellQuoted(trustedRequirement)

        return [
            "set -eu",
            "src=\(sourceQ)",
            "dest=\(destinationQ)",
            "stage=\(stagingQ)",
            "backup=\(backupQ)",
            "failed=\(failedQ)",
            "stage_leaf=\(stageLeafQ)",
            "had_dest=0",
            "new_installed=0",
            "expected_version=\(expectedVersionQ)",
            "old_version=\(oldVersionQ)",
            "trusted_requirement=\(requirementQ)",
            "validate_app() { candidate=\"$1\"; required_version=\"$2\"; plist=\"$candidate/Contents/Info.plist\"; test -d \"$candidate/Contents/MacOS\"; test -f \"$plist\"; bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$plist\"); test \"$bundle_id\" = \(bundleIDQ); package_type=$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' \"$plist\"); test \"$package_type\" = APPL; short_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \"$plist\"); build_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \"$plist\"); test \"$short_version\" = \"$required_version\"; test \"$build_version\" = \"$required_version\"; executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \"$plist\"); test -n \"$executable\"; case \"$executable\" in */*|*\\\\*) return 1 ;; esac; test -x \"$candidate/Contents/MacOS/$executable\"; /usr/bin/codesign --verify --deep --strict --all-architectures -R=\"$trusted_requirement\" \"$candidate\" >/dev/null 2>&1; }",
            "rollback() { if test -e \"$backup\"; then if test -e \"$dest\"; then /bin/mv \"$dest\" \"$failed\" || return 1; fi; if /bin/mv \"$backup\" \"$dest\"; then /bin/rm -rf \"$failed\"; else if test ! -e \"$dest\" && test -e \"$failed\"; then /bin/mv \"$failed\" \"$dest\" || true; elif test ! -e \"$dest\" && test -e \"$stage\"; then /bin/mv \"$stage\" \"$dest\" || true; fi; return 1; fi; elif test \"$new_installed\" -eq 1 && test -e \"$dest\"; then /bin/mv \"$dest\" \"$failed\"; /bin/rm -rf \"$failed\"; fi; }",
            "finish_on_error() { rc=$?; rollback_rc=0; if test \"$rc\" -ne 0; then rollback || rollback_rc=$?; fi; if test \"$rollback_rc\" -eq 0; then /bin/rm -rf \"$stage\"; fi; exit \"$rc\"; }",
            // A UUID collision should fail without deleting or interpreting any pre-existing
            // artifact as this transaction's backup. Install the trap only after this guard.
            "test ! -e \"$stage\"",
            "test ! -e \"$backup\"",
            "test ! -e \"$failed\"",
            "if test -e \"$dest\"; then had_dest=1; fi",
            "trap finish_on_error EXIT",
            "/usr/bin/ditto \"$src\" \"$stage\"",
            "validate_app \"$stage\" \"$expected_version\"",
            "validate_app \"$dest\" \"$old_version\"",
            "if test \"$had_dest\" -eq 1; then test -e \"$dest\"; /bin/mv \"$dest\" \"$backup\"; else test ! -e \"$dest\"; fi",
            "/bin/mv \"$stage\" \"$dest\"",
            "if test -e \"$dest/$stage_leaf\"; then /bin/mv \"$dest/$stage_leaf\" \"$stage\" || true; /usr/bin/false; fi",
            "new_installed=1",
            "validate_app \"$dest\" \"$expected_version\"",
            "/bin/rm -rf \"$backup\"",
            "trap - EXIT",
            "/usr/bin/true",
        ].joined(separator: "; ")
    }

    /// POSIX shell 单引号转义。`'` 需要结束当前字符串、写入转义单引号、再重新进入单引号。
    static func shellQuoted(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    // MARK: 双路径核心 —— 无提权快路径可行性判定（与 Sparkle 无密码启发式一致）
    //
    // 安装器替换 /Applications/Plumb.app 有两条路径：
    //   - 快路径：当前进程能无提权替换（FileManager staging/backup/rename），零密码、零 AppleScript。
    //   - 提权路径：AppleScript `with administrator privileges`（弹系统密码框）。
    //
    // 触发快路径的条件（与 Sparkle 一致）：
    //   - 目标 .app 不存在：父目录当前 uid 可写即可直接创建；
    //   - 目标 .app 存在：仅当其 owner == 当前 uid，才尝试同目录事务替换；若父目录
    //     权限仍阻止 rename，快路径会在旧 app 未丢失的前提下失败并回退到提权路径。
    // 任一不满足 → 返回 false → 安装器走提权路径。
    //
    // 这是纯函数（依赖全注入），可在单测里覆盖 root-owned / admin-owned / 不存在 等
    // 全部分支，无需在测试进程里构造真实 root 文件。

    /// 判定当前进程能否无提权替换目标。纯函数版本：所有外部状态以参数注入，可单测。
    static func canReplaceWithoutPrivileges(
        destination: String,
        destinationExists: Bool,
        destinationOwnerUID: uid_t,
        parentDirectoryWritable: Bool,
        currentUID: uid_t
    ) -> Bool {
        if destinationExists {
            // 目标存在：只有当目标归当前用户所有时，才能无提权删除替换。
            return destinationOwnerUID == currentUID
        }
        // 目标不存在：能否无提权创建取决于父目录是否当前用户可写。
        return parentDirectoryWritable
    }

    /// 判定当前进程能否无提权替换目标的便捷重载：从真实文件系统读取状态。
    /// 读不到属性（理论上不应发生）→ 保守返回 false，走提权路径兜底。
    static func canReplaceWithoutPrivileges(destination: String) -> Bool {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: destination)
        let parent = (destination as NSString).deletingLastPathComponent
        let parentWritable = fm.isWritableFile(atPath: parent)
        let ownerUID: uid_t
        if exists {
            ownerUID = (try? fm.attributesOfItem(atPath: destination)[.ownerAccountID] as? uid_t) ?? uid_t.max
        } else {
            ownerUID = uid_t.max   // 不存在时不参与判定
        }
        return canReplaceWithoutPrivileges(
            destination: destination,
            destinationExists: exists,
            destinationOwnerUID: ownerUID,
            parentDirectoryWritable: parentWritable,
            currentUID: getuid())
    }

    /// Same-directory transactional replacement. Source is copied into staging first so the
    /// running installer bundle remains intact. The old app is kept as a backup until the new
    /// destination has passed validation; every failure after backup creation restores it.
    static func replaceWithoutPrivileges(
        source: String,
        destination: String,
        transactionID: String = UUID().uuidString,
        operations: InstallFileOperations = .live,
        validator: (String) throws -> Void,
        destinationValidator: (() throws -> Void)? = nil
    ) throws {
        let canonicalSource = canonicalPath(source)
        let canonicalDestination = canonicalPath(destination)
        guard canonicalSource != canonicalDestination else {
            throw InstallError.sourceMatchesDestination
        }
        guard operations.fileExists(canonicalSource) else {
            throw InstallError.missingAppPath
        }

        let paths = try transactionPaths(
            destination: canonicalDestination,
            transactionID: transactionID
        )
        guard !operations.fileExists(paths.staging),
              !operations.fileExists(paths.backup),
              !operations.fileExists(paths.failed)
        else {
            throw InstallError.invalidAppBundle(reason: "transaction path collision")
        }

        let sourceURL = URL(fileURLWithPath: canonicalSource)
        let destinationURL = URL(fileURLWithPath: canonicalDestination)
        let stagingURL = URL(fileURLWithPath: paths.staging)
        let backupURL = URL(fileURLWithPath: paths.backup)
        let failedURL = URL(fileURLWithPath: paths.failed)
        let validate = validator
        var oldAppBackedUp = false
        var newAppInstalled = false
        var preserveRecoveryArtifacts = false

        defer {
            if operations.fileExists(paths.staging) {
                try? operations.removeItem(stagingURL)
            }
            if !preserveRecoveryArtifacts, operations.fileExists(paths.failed) {
                try? operations.removeItem(failedURL)
            }
            if !preserveRecoveryArtifacts, operations.fileExists(paths.backup) {
                try? operations.removeItem(backupURL)
            }
        }

        do {
            try operations.copyItem(sourceURL, stagingURL)
            try validate(paths.staging)
            try destinationValidator?()

            if operations.fileExists(canonicalDestination) {
                try operations.moveItem(destinationURL, backupURL)
                oldAppBackedUp = true
            }
            try operations.moveItem(stagingURL, destinationURL)
            newAppInstalled = true
            try validate(canonicalDestination)

            if oldAppBackedUp {
                try operations.removeItem(backupURL)
                oldAppBackedUp = false
            }
        } catch {
            if oldAppBackedUp {
                do {
                    if operations.fileExists(canonicalDestination) {
                        try operations.moveItem(destinationURL, failedURL)
                    }
                    try operations.moveItem(backupURL, destinationURL)
                    oldAppBackedUp = false
                    if operations.fileExists(paths.failed) {
                        try? operations.removeItem(failedURL)
                    }
                } catch {
                    // The old app remains at backup. If restoring it failed after the new app
                    // was moved aside, put the new app back at the public destination so the
                    // machine is never left with no launchable Plumb.app. Preserve every
                    // recovery artifact if even that best-effort move fails.
                    preserveRecoveryArtifacts = true
                    if !operations.fileExists(canonicalDestination) {
                        if operations.fileExists(paths.failed) {
                            try? operations.moveItem(failedURL, destinationURL)
                        } else if operations.fileExists(paths.staging) {
                            try? operations.moveItem(stagingURL, destinationURL)
                        }
                    }
                    throw InstallError.rollbackFailed(backupPath: paths.backup)
                }
            } else if newAppInstalled, operations.fileExists(canonicalDestination) {
                try? operations.removeItem(destinationURL)
            }
            throw error
        }
    }

    static func captureInstalledTrust(
        destination: String = destination
    ) throws -> UpdateInstallTrust {
        let canonical = canonicalPath(destination)
        guard let installedVersion = bundleVersion(at: canonical),
              AppVersion(parsing: installedVersion) != nil
        else {
            throw InstallError.invalidAppBundle(reason: "trusted destination version is missing or invalid")
        }
        let requirement = try designatedRequirementString(at: canonical)
        try validateAppBundle(
            at: canonical,
            expectedVersion: installedVersion,
            signatureVerifier: { verifyCodeSignature($0, requirement: requirement) })
        return UpdateInstallTrust(
            designatedRequirement: requirement,
            installedVersion: installedVersion)
    }

    static func validateInstallCandidate(
        at path: String,
        expectedVersion: String,
        trust: UpdateInstallTrust
    ) throws {
        guard let oldVersion = AppVersion(parsing: trust.installedVersion) else {
            throw InstallError.invalidAppBundle(reason: "invalid trusted destination version")
        }
        try validateAppBundle(
            at: path,
            expectedVersion: expectedVersion,
            versionMustBeNewerThan: oldVersion,
            signatureVerifier: {
                verifyCodeSignature($0, requirement: trust.designatedRequirement)
            })
        try UpdateDownloader.validateNoSymbolicLinks(in: URL(fileURLWithPath: canonicalPath(path)))
    }

    static func validateTrustedDestination(
        at path: String = destination,
        trust: UpdateInstallTrust
    ) throws {
        try validateAppBundle(
            at: path,
            expectedVersion: trust.installedVersion,
            signatureVerifier: {
                verifyCodeSignature($0, requirement: trust.designatedRequirement)
            })
    }

    static func validateAppBundle(
        at path: String,
        expectedBundleIdentifier: String = expectedBundleIdentifier,
        expectedVersion: String? = nil,
        versionMustBeNewerThan: AppVersion? = nil,
        signatureVerifier: (String) -> Bool
    ) throws {
        let canonical = canonicalPath(path)
        let appURL = URL(fileURLWithPath: canonical)
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
              isDirectory.boolValue,
              appURL.pathExtension.lowercased() == "app",
              let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = plist as? [String: Any],
              info["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
              info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              !executable.contains("/"),
              !executable.contains("\\")
        else {
            throw InstallError.invalidAppBundle(reason: "invalid bundle structure")
        }
        if let expectedVersion {
            guard info["CFBundleShortVersionString"] as? String == expectedVersion,
                  info["CFBundleVersion"] as? String == expectedVersion,
                  let parsed = AppVersion(parsing: expectedVersion),
                  versionMustBeNewerThan.map({ parsed > $0 }) ?? true
            else {
                throw InstallError.invalidAppBundle(reason: "unexpected or non-increasing bundle version")
            }
        } else if versionMustBeNewerThan != nil {
            throw InstallError.invalidAppBundle(reason: "missing expected bundle version")
        }
        let executablePath = appURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executable)
            .path
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw InstallError.invalidAppBundle(reason: "missing executable")
        }
        guard signatureVerifier(canonical) else {
            throw InstallError.invalidAppBundle(reason: "invalid code signature")
        }
    }

    static func bundleVersion(at path: String) -> String? {
        let infoURL = URL(fileURLWithPath: canonicalPath(path))
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = plist as? [String: Any],
              let shortVersion = info["CFBundleShortVersionString"] as? String,
              info["CFBundleVersion"] as? String == shortVersion
        else { return nil }
        return shortVersion
    }

    private static func designatedRequirementString(at path: String) throws -> String {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: canonicalPath(path)) as CFURL,
            SecCSFlags(),
            &code)
        guard status == errSecSuccess, let code else {
            throw InstallError.invalidAppBundle(reason: "cannot read trusted destination signature")
        }
        let strictFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        status = SecStaticCodeCheckValidity(code, strictFlags, nil)
        guard status == errSecSuccess else {
            throw InstallError.invalidAppBundle(reason: "trusted destination signature is invalid")
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            throw InstallError.invalidAppBundle(reason: "trusted destination has no designated requirement")
        }
        var requirementText: CFString?
        status = SecRequirementCopyString(requirement, SecCSFlags(), &requirementText)
        guard status == errSecSuccess, let requirementText else {
            throw InstallError.invalidAppBundle(reason: "cannot serialize trusted designated requirement")
        }
        return requirementText as String
    }

    private static func verifyCodeSignature(_ path: String, requirement: String) -> Bool {
        var parsedRequirement: SecRequirement?
        var status = SecRequirementCreateWithString(
            requirement as CFString,
            SecCSFlags(),
            &parsedRequirement)
        guard status == errSecSuccess, let parsedRequirement else { return false }

        var code: SecStaticCode?
        status = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: canonicalPath(path)) as CFURL,
            SecCSFlags(),
            &code)
        guard status == errSecSuccess, let code else { return false }
        let strictFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, strictFlags, parsedRequirement) == errSecSuccess
    }

    /// 把 shell 命令包成单行 AppleScript：`do shell script "… ; echo $?" with administrator privileges`。
    ///
    /// 关键不变量：**生成的 AppleScript 必须是单行**（不含 `\n`）。多行形式
    /// （"..." 换行 with administrator privileges）能通过 compileAndReturnError，
    /// 但 executeAndReturnError 报 -2741 "Expected timeout or transaction but
    /// found identifier" —— 这是历史上阻塞每次 OTA 更新的根因。该不变量由单测
    /// `appleScriptIsSingleLine` 钉死，防回归。
    static func buildAppleScript(shellScript: String) -> String {
        // 转义反斜杠与双引号，安全嵌入 AppleScript 字符串。
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // 必须单行：见上文不变量说明。
        return "do shell script \"\(escaped) ; echo $?\" with administrator privileges"
    }

    /// 启动重开脚本并等待其中 `/usr/bin/open` 的真实退出码。旧实现只观察 `Process.run()`，
    /// 随后无条件 exit(0)；脚本里的 open 即使失败也无人知晓。这里等待脚本结束，只有 status=0
    /// 才允许调用方退出当前进程。
    static func executeRelaunchScript(at scriptURL: URL) async throws {
        let status: Int32
        do {
            status = try await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = scriptURL
                process.standardInput = FileHandle(forWritingAtPath: "/dev/null")
                process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
                process.standardError = FileHandle(forWritingAtPath: "/dev/null")
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }.value
        } catch {
            throw InstallError.relaunchFailed
        }
        guard status == 0 else { throw InstallError.relaunchFailed }
    }

    static func launchAndObserveRelaunch(
        appPath: String,
        delaySeconds: Int,
        arguments: [String] = [],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws {
        let scriptURL = temporaryDirectory
            .appendingPathComponent("plumb-relaunch-\(UUID().uuidString).sh")
        let script = UpdateRelaunchCommand.buildScript(
            appPath: appPath,
            delaySeconds: delaySeconds,
            arguments: arguments)
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path)
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            throw InstallError.relaunchFailed
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try await executeRelaunchScript(at: scriptURL)
    }
}

@MainActor
final class UpdateInstallerDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private let expectedVersion: String
    private let isCommandLineHandoff: Bool
    /// 从 captureInstalledTrust 之前持有到新版 open 被 LaunchServices 接受。
    /// 快路径与提权路径共用此单一所有权，不各自建锁。
    private var destinationLock: UpdateInstallDestinationLock?

    init(
        expectedVersion: String,
        isCommandLineHandoff: Bool = UpdateInstallerHandoff.parse(
            arguments: CommandLine.arguments) != nil
    ) {
        self.expectedVersion = expectedVersion
        self.isCommandLineHandoff = isCommandLineHandoff
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow()
        // Run the install synchronously on the main run loop's next iteration so the
        // window paints before the (brief, blocking) privileged replace runs.
        DispatchQueue.main.async { [weak self] in
            self?.runInstall()
        }
    }

    private func setupWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = L10n.otaInstallingTitle
        let label = NSTextField(labelWithString: L10n.otaInstallingMessage)
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 40, width: 320, height: 40)
        w.contentView?.addSubview(label)
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        statusLabel = label
    }

    private func runInstall() {
        DiagnosticLog.debug("OTA-installer: runInstall START")
        do {
            // 必须在读取旧 destination 的签名/版本之前取得跨进程锁。
            // 否则两个 installer 会捕获同一旧锚点，却交错备份/回滚同一路径。
            destinationLock = try UpdateInstallDestinationLock.acquire()
            try performInstall()
            DiagnosticLog.debug("OTA-installer: install succeeded, relaunching")
        } catch {
            DiagnosticLog.debug("OTA-installer: install FAILED: \(error)")
            releaseDestinationLock()
            fail(with: error)
            return
        }

        // Keep the installer alive until the relaunch script has reported the real
        // `/usr/bin/open` exit status. Waiting happens off the main actor so the status
        // window remains responsive; only a confirmed success terminates this process.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.finishAndRelaunch()
                self.cleanupTemporaryInstallerSourceIfSafe()
                self.releaseDestinationLock()
                exit(0)
            } catch {
                DiagnosticLog.debug("OTA-installer: relaunch FAILED: \(error)")
                self.releaseDestinationLock()
                self.fail(with: error)
            }
        }
    }

    /// 事务替换 /Applications/Plumb.app。双路径分流（与 Sparkle 无密码启发式一致）：
    ///   - 快路径：目标可无提权替换 → 同目录 staging/backup/rollback，零密码、零 AppleScript。
    ///   - 提权路径：AppleScript `with administrator privileges`（弹系统密码框）。
    /// 快路径失败时回退提权路径（兜底，不丢功能）。
    private func performInstall() throws {
        // 新流程的唯一源是正在运行的下载 bundle。argv 只携带期望版本，不携带可写路径；
        // 旧 UserDefaults 仅在 main.swift 已证明其路径精确等于 Bundle.main 时用于兼容启动。
        let srcPath = UpdateInstallerCommand.canonicalPath(Bundle.main.bundlePath)
        guard srcPath != UpdateInstallerCommand.canonicalPath(UpdateInstallerCommand.destination) else {
            throw InstallError.sourceMatchesDestination
        }

        // 在任何 staging/替换前，从旧安装目标捕获 designated requirement 与版本锚点。
        // source 必须同签名、版本精确等于 handoff 且严格高于旧版；这也让可写 argv/defaults
        // 无法把任意签名候选提升为可信更新。
        let trust = try UpdateInstallerCommand.captureInstalledTrust()
        try UpdateInstallerCommand.validateInstallCandidate(
            at: srcPath,
            expectedVersion: expectedVersion,
            trust: trust)

        // 快路径：当前用户可无提权替换目标（admin-owned 或新装到可写父目录）。
        if UpdateInstallerCommand.canReplaceWithoutPrivileges(destination: UpdateInstallerCommand.destination) {
            do {
                DiagnosticLog.debug("OTA-installer: fast path (no privileges) src=\(srcPath)")
                try UpdateInstallerCommand.replaceWithoutPrivileges(
                    source: srcPath,
                    destination: UpdateInstallerCommand.destination,
                    validator: { candidate in
                        try UpdateInstallerCommand.validateInstallCandidate(
                            at: candidate,
                            expectedVersion: self.expectedVersion,
                            trust: trust)
                    },
                    destinationValidator: {
                        try UpdateInstallerCommand.validateTrustedDestination(trust: trust)
                    })
                DiagnosticLog.debug("OTA-installer: fast path OK")
                return
            } catch {
                // A failed rollback must stop here: the old app is deliberately preserved at
                // the reported backup path for manual recovery. Ordinary failures are safe to
                // retry through the privileged transaction because rollback already restored
                // the original destination and the source was copied rather than moved.
                if let installError = error as? InstallError {
                    switch installError {
                    case .rollbackFailed, .sourceMatchesDestination, .invalidAppBundle, .missingAppPath:
                        throw installError
                    default:
                        break
                    }
                }
                DiagnosticLog.debug("OTA-installer: fast path FAILED (\(error)), falling back to privileged")
            }
        }

        // 提权路径：AppleScript with administrator privileges。
        DiagnosticLog.debug("OTA-installer: privileged path src=\(srcPath)")
        let shellScript = try UpdateInstallerCommand.buildShellScript(
            source: srcPath,
            expectedVersion: expectedVersion,
            trustedRequirement: trust.designatedRequirement,
            trustedDestinationVersion: trust.installedVersion)
        let status = try runPrivileged(shellScript: shellScript)
        guard status == 0 else { throw InstallError.replaceFailed(status: status) }
        DiagnosticLog.debug("OTA-installer: privileged path OK")
    }

    /// 通过 AppleScript 提权执行 shell 命令。
    /// 用户取消密码框（-128）抛 authorizationDenied；其它失败（密码错误、命令失败等）抛 replaceFailed。
    /// 成功则返回子进程 exit code。
    @discardableResult
    private func runPrivileged(shellScript: String) throws -> Int {
        // 委托给纯函数构造单行 AppleScript（不变量：必须单行，否则 -2741）。
        let appleScript = UpdateInstallerCommand.buildAppleScript(shellScript: shellScript)
        var errorInfo: NSDictionary?
        guard let result = NSAppleScript(source: appleScript)?.executeAndReturnError(&errorInfo) else {
            // 区分"用户主动取消"（error number -128）和其它失败（密码错误、超时、命令失败等）。
            let errNumber = errorInfo?["NSAppleScriptErrorNumber"] as? Int ?? 0
            if errNumber == -128 {
                throw InstallError.authorizationDenied
            }
            throw InstallError.replaceFailed(status: errNumber)
        }
        // 解析 "echo $?" 输出的最后一行数字作为 exit code。
        let out = result.stringValue ?? ""
        let exitCode = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        return exitCode
    }

    /// 安装完成后可靠重启新版本。
    ///
    /// 用独立脚本执行 `sleep; open -n <dest>`，并等待脚本返回 `/usr/bin/open` 的真实
    /// exit status。仅脚本进程成功创建并不代表 LaunchServices 已接受重开请求；旧实现
    /// 在 0.5 秒后无条件 exit(0)，会把 open 失败静默伪装成安装成功。
    private func finishAndRelaunch() async throws {
        statusLabel?.stringValue = L10n.otaInstallDone
        try await UpdateInstallerCommand.launchAndObserveRelaunch(
            appPath: UpdateInstallerCommand.destination,
            delaySeconds: 1)
    }

    /// 只清理新 argv handoff 的 downloader 临时源。除了纯路径策略，还要求
    /// 父目录当前只含正在运行的 Plumb.app，避免删除临时目录中的其他文件。
    private func cleanupTemporaryInstallerSourceIfSafe() {
        let bundleURL = Bundle.main.bundleURL
        guard let parent = UpdateInstallerTemporarySourceCleanupPolicy.removableParentDirectory(
            bundleURL: bundleURL,
            temporaryDirectory: FileManager.default.temporaryDirectory,
            isCommandLineHandoff: isCommandLineHandoff)
        else {
            DiagnosticLog.debug("OTA-installer: temporary source cleanup skipped (policy)")
            return
        }

        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil,
                options: [])
            let canonicalBundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            guard children.count == 1,
                  children[0].standardizedFileURL.resolvingSymlinksInPath() == canonicalBundle
            else {
                DiagnosticLog.debug("OTA-installer: temporary source cleanup skipped (unexpected siblings)")
                return
            }
            try FileManager.default.removeItem(at: parent)
            DiagnosticLog.debug("OTA-installer: removed temporary source parent=\(parent.path)")
        } catch {
            // 新版已安装且 open 已成功；临时清理失败不得反转为安装失败。
            DiagnosticLog.debug("OTA-installer: temporary source cleanup FAILED: \(error)")
        }
    }

    private func releaseDestinationLock() {
        destinationLock?.release()
        destinationLock = nil
    }

    private func fail(with error: Error) {
        let msg: String
        switch error {
        case InstallError.authorizationDenied: msg = L10n.otaInstallCanceled
        case InstallError.missingAppPath: msg = L10n.otaInstallFailed
        case InstallError.sourceMatchesDestination: msg = L10n.otaInstallFailed
        case InstallError.invalidAppBundle: msg = L10n.otaInstallFailed
        case InstallError.rollbackFailed: msg = L10n.otaInstallFailed
        case InstallError.replaceFailed: msg = L10n.otaInstallFailed
        case InstallError.installLockUnavailable: msg = L10n.otaInstallFailed
        case InstallError.relaunchFailed: msg = L10n.otaInstallFailed
        default: msg = L10n.otaInstallFailed
        }
        releaseDestinationLock()
        // 只清理旧版兼容标志；新 argv handoff 不依赖 UserDefaults。
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: UpdateConfig.installerModeKey)
        defaults.removeObject(forKey: UpdateConfig.installerAppPathKey)

        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = msg
        a.addButton(withTitle: "OK")
        a.runModal()
        exit(1)
    }
}
