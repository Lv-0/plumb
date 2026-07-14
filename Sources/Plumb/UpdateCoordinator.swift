import Foundation
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateCoordinator
//
// 模块角色：OTA 流程编排者，主 app 的唯一入口。
//
// 职责：
//   - 后台静默检查（启动时，失败静默）。
//   - 手动检查（用户点菜单，失败弹窗）。
//   - 检测到更新 → 展示版本信息 → 用户确认 → 下载 → sha256 校验 →
//     写 installerMode 标志 + 待安装路径 → 以 Launch Services 重开自身进入安装器。
//
// 设计说明：主 app 永不提权、不碰 /Applications；替换职责交给安装器进程。
// ─────────────────────────────────────────────────────────────────────────────

extension UpdateConfig {
    /// installer 模式触发标志（UserDefaults）。
    static let installerModeKey = "installerMode"
    /// installer 模式读取的待安装 app 临时路径（UserDefaults）。
    static let installerAppPathKey = "installerAppPath"
    /// 后台检查最小间隔（秒），避免每次启动都请求。
    static let backgroundCheckMinInterval: TimeInterval = 6 * 3600
    /// 上次后台检查时间戳（UserDefaults）。
    static let lastCheckKey = "otaLastCheckTimestamp"
    /// 「打开设置」自动检查的独立短节流间隔（秒）。
    /// 与后台 6h 节流解耦：打开设置是用户主动行为，理应及时检查；但又不能每次开关/重开窗口都请求，
    /// 故保留一个短节流（避免用户在设置窗口里反复点 tab/重开触发连发请求）。短于 6h 后台节流，
    /// 确保用户重新打开设置（即便后台节流未过）也能拿到较新的更新状态。
    static let settingsOpenCheckMinInterval: TimeInterval = 10 * 60
    /// 上次「打开设置」检查时间戳（UserDefaults，独立于 lastCheckKey）。
    static let settingsOpenCheckLastKey = "otaLastSettingsOpenCheckTimestamp"
}

enum UpdateRelaunchCommand {
    static func buildScript(
        appPath: String,
        delaySeconds: Int = 2,
        arguments: [String] = []
    ) -> String {
        let argumentSuffix = arguments.isEmpty
            ? ""
            : " --args " + arguments.map(UpdateInstallerCommand.shellQuoted).joined(separator: " ")
        return "#!/bin/bash\nsleep \(delaySeconds)\n/usr/bin/open -n \(UpdateInstallerCommand.shellQuoted(appPath))\(argumentSuffix)\n"
    }
}

/// 更新检查结果的展示语义。静默请求可以被后来的手动请求升级，
/// 但同一时刻始终只有一个真实网络检查。
enum UpdateCheckPresentation: Equatable {
    case silent
    case manual
}

/// OTA 顶层流程状态。整个 Coordinator 共享一个状态门禁，避免独立的
/// 启动/设置/手动入口各自拉取、弹窗和下载，最后竞争 installerMode。
enum UpdateFlowPhase: Equatable {
    case idle
    case checking
    case presenting
    case downloading
    case handingOffToInstaller
}

/// 纯状态门禁（无 AppKit/网络依赖），便于用单测钉死 single-flight 语义。
struct UpdateFlowGate {
    private(set) var phase: UpdateFlowPhase = .idle
    private var pendingPresentation: UpdateCheckPresentation = .silent

    /// 返回 true 表示调用者获得本轮检查所有权，应实际启动 fetch。
    /// checking 期间的重复请求被合并；其中任意手动请求会把最终展示升级为 manual。
    mutating func requestCheck(_ presentation: UpdateCheckPresentation) -> Bool {
        switch phase {
        case .idle:
            phase = .checking
            pendingPresentation = presentation
            return true
        case .checking:
            if presentation == .manual {
                pendingPresentation = .manual
            }
            return false
        case .presenting, .downloading, .handingOffToInstaller:
            return false
        }
    }

    /// 一次真实检查完成，转入结果展示阶段，并返回合并后的展示语义。
    mutating func completeCheck() -> UpdateCheckPresentation? {
        guard phase == .checking else { return nil }
        phase = .presenting
        let presentation = pendingPresentation
        pendingPresentation = .silent
        return presentation
    }

    /// 无更新、用户取消或结果提示结束后回到 idle。
    mutating func finishPresentation() {
        guard phase == .presenting else { return }
        phase = .idle
    }

    /// 只允许已展示的单一更新进入下载。
    mutating func beginDownload() -> Bool {
        guard phase == .presenting else { return false }
        phase = .downloading
        return true
    }

    /// 只允许当前单一下载进入 installer handoff。
    mutating func beginInstallerHandoff() -> Bool {
        guard phase == .downloading else { return false }
        phase = .handingOffToInstaller
        return true
    }

    /// 取消/失败统一回收所有权。
    mutating func reset() {
        phase = .idle
        pendingPresentation = .silent
    }
}

@MainActor
final class UpdateCoordinator {
    static let shared = UpdateCoordinator()

    private let checker: UpdateChecker
    private let downloader: UpdateDownloader

    /// 所有检查入口共享的单飞状态门禁。
    private var flowGate = UpdateFlowGate()

    /// 当前唯一检查 Task。重复请求由 flowGate 合并，不另起 Task。
    private var currentCheckTask: Task<Void, Never>?

    /// 当前下载 Task（用于 Cancel 时协作式取消）。
    private var currentDownloadTask: Task<Void, Never>?

    /// 是否允许「自动」检查更新（启动、后台定期、打开设置）的判定闭包。
    /// 默认返回 true（保持既有行为）；AppDelegate 启动时注入真实读取（读 settings.autoCheckUpdates）。
    /// 仅用于收敛所有自动路径的开关判定；手动检查（checkForUpdatesManually）不受此闭包影响。
    /// 之所以用闭包而非直接读 store：解耦 UpdateCoordinator 与设置存储，便于单测注入固定值。
    var autoCheckUpdatesProvider: () -> Bool = { true }

    private init() {
        self.checker = UpdateChecker()
        self.downloader = UpdateDownloader()
    }

    /// 测试用初始化器：注入自定义 checker（如带计数 fetcher），便于断言「检查是否真的发起」。
    /// 生产代码请用 `UpdateCoordinator.shared`。
    init(checker: UpdateChecker, downloader: UpdateDownloader = UpdateDownloader()) {
        self.checker = checker
        self.downloader = downloader
    }

    /// 单测辅助：设置 autoCheckUpdatesProvider 的返回值（模拟用户开关）。
    func setAutoCheckEnabled(_ enabled: Bool) {
        autoCheckUpdatesProvider = { enabled }
    }

    private var osVersion: AppVersion {
        let raw = ProcessInfo.processInfo.operatingSystemVersion
        return AppVersion(major: raw.majorVersion, minor: raw.minorVersion, patch: raw.patchVersion)
    }

    /// 启动后台静默检查。失败完全静默（不打扰）；节流避免每次启动都请求。
    /// 调用方：AppDelegate 启动时、后台 6h 定时器。
    /// 开关判定：autoCheckUpdatesProvider 返回 false 时直接返回（不写 lastCheckKey，
    /// 保证用户重新开启开关时可立即检查）。手动检查路径不受此开关影响。
    func checkForUpdatesInBackground() {
        guard autoCheckUpdatesProvider() else { return } // 自动检查被用户关闭 → 跳过。
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: UpdateConfig.lastCheckKey) as? Double,
           Date().timeIntervalSince1970 - last < UpdateConfig.backgroundCheckMinInterval {
            return // 节流：距离上次检查不足间隔，跳过。
        }
        defaults.set(Date().timeIntervalSince1970, forKey: UpdateConfig.lastCheckKey)
        requestCheck(presentation: .silent)
    }

    /// 打开/重开设置窗口时触发的自动检查。
    ///
    /// 与 `checkForUpdatesInBackground` 的关键区别：**使用独立短节流**（`settingsOpenCheckMinInterval`，
    /// 默认 10min），不共用后台 6h 节流——否则用户刚启动 app（后台已检查）后立即打开设置会被 6h
    /// 节流吞掉，与设置页文案「打开设置时自动检查」不符。打开设置是用户主动行为，理应及时检查；
    /// 短节流仅用于防止在设置窗口内反复切 tab/重开触发连发请求。
    ///
    /// 开关与后台路径一致：autoCheckUpdatesProvider 返回 false 时跳过（用户关闭自动检查 →
    /// 打开设置也不自动查，需用户手动点「检查更新」）。失败静默（与后台一致）。
    func checkForUpdatesWhenOpeningSettings() {
        guard autoCheckUpdatesProvider() else { return } // 自动检查被用户关闭 → 跳过。
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: UpdateConfig.settingsOpenCheckLastKey) as? Double,
           Date().timeIntervalSince1970 - last < UpdateConfig.settingsOpenCheckMinInterval {
            return // 独立短节流：防止设置窗口内反复重开触发连发请求。
        }
        defaults.set(Date().timeIntervalSince1970, forKey: UpdateConfig.settingsOpenCheckLastKey)
        requestCheck(presentation: .silent)
    }

    /// 手动检查。失败弹窗提示（不阻塞 app）。
    func checkForUpdatesManually() {
        requestCheck(presentation: .manual)
    }

    /// 统一检查入口。启动/设置/手动调用只决定展示语义，不再各自创建 Task。
    private func requestCheck(presentation: UpdateCheckPresentation) {
        guard flowGate.requestCheck(presentation) else {
            DiagnosticLog.debug("OTA: coalesced check request presentation=\(presentation) phase=\(flowGate.phase)")
            return
        }

        let checker = self.checker
        let currentVersion = AppVersion.current
        let currentOS = osVersion
        currentCheckTask = Task { [weak self] in
            let result = await checker.check(current: currentVersion, osVersion: currentOS)
            guard !Task.isCancelled, let self else { return }
            self.completeCheck(with: result)
        }
    }

    /// 回收检查 Task，且在 presenting 所有权下完成唯一一次结果处理。
    private func completeCheck(with result: UpdateResult) {
        guard let presentation = flowGate.completeCheck() else { return }
        currentCheckTask = nil

        switch result {
        case .available(let manifest):
            if askToInstall(manifest: manifest) {
                guard flowGate.beginDownload() else {
                    flowGate.reset()
                    return
                }
                startUpdate(manifest: manifest)
            } else {
                flowGate.finishPresentation()
            }
        case .upToDate:
            if presentation == .manual {
                alert(title: L10n.otaUpToDate, message: "")
            }
            flowGate.finishPresentation()
        case .osTooOld:
            if presentation == .manual {
                // 保留现有用户语义：当前系统无可安装更新时显示“已是最新”。
                alert(title: L10n.otaUpToDate, message: "")
            }
            flowGate.finishPresentation()
        case .error:
            if presentation == .manual {
                alert(title: L10n.otaCheckFailed, message: L10n.otaCheckFailedHint)
            }
            flowGate.finishPresentation()
        }
    }

    /// 展示"有新版本"提示，返回用户是否确认更新。
    private func askToInstall(manifest: UpdateManifest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: L10n.otaNewVersionTitle, manifest.version)
        alert.informativeText = manifest.notes(for: AppLanguage.current)
        alert.addButton(withTitle: L10n.otaUpdateNow)
        alert.addButton(withTitle: L10n.otaCancel)
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    /// 下载 → 校验 → 解压 → 写标志 → 重开自身进入安装器。
    ///
    /// 下载阶段弹出进度窗口（百分比 + 字节数 + Cancel）。
    /// 用户点 Cancel → 取消下载 Task → downloader 抛 CancellationError → 静默关闭窗口。
    private func startUpdate(manifest: UpdateManifest) {
        guard flowGate.phase == .downloading, currentDownloadTask == nil else {
            DiagnosticLog.debug("OTA: refused duplicate download phase=\(flowGate.phase) taskExists=\(currentDownloadTask != nil)")
            return
        }
        DiagnosticLog.debug("OTA: update confirmed by user, target=\(manifest.version) starting download")

        let progressWindow = UpdateProgressWindow(version: manifest.version)
        progressWindow.onCancel = { [weak self] in
            // 协作式取消：downloader.download 会抛 CancellationError。
            self?.currentDownloadTask?.cancel()
        }
        progressWindow.show()

        let task = Task { [weak self] in
            guard let self else { return }
            var preparedApp: URL?
            defer {
                if let preparedApp {
                    try? FileManager.default.removeItem(
                        at: preparedApp.deletingLastPathComponent())
                }
            }
            do {
                let zip = try await self.downloader.download(from: manifest.url) { downloaded, total in
                    // downloader 回调线程不保证；切回 MainActor 更新 UI。
                    Task { @MainActor in
                        progressWindow.updateProgress(bytesDownloaded: downloaded, totalBytes: total)
                    }
                }
                defer { try? FileManager.default.removeItem(at: zip) }
                DiagnosticLog.debug("OTA: downloaded \(manifest.version)")
                let newApp = try await self.downloader.prepareDownloadedUpdate(
                    zip: zip,
                    expectedSHA256: manifest.sha256,
                    expectedVersion: manifest.version)
                preparedApp = newApp
                // `Task.cancel()` can race with a detached verifier finishing. Do not close the
                // progress UI or transfer ownership to the installer until this MainActor task
                // has observed every Cancel action queued while the window was still usable.
                try Task.checkCancellation()
                // A successful handoff terminates with `exit(0)`, which does not unwind Swift
                // `defer` blocks. Remove the archive explicitly before that point; otherwise
                // every successful update leaks the (up to 512 MiB) downloaded zip.
                do {
                    try FileManager.default.removeItem(at: zip)
                } catch {
                    DiagnosticLog.debug("OTA: downloaded archive cleanup FAILED: \(error)")
                }
                DiagnosticLog.debug("OTA: unzipped → \(newApp.path), relaunching into installer")
                progressWindow.close()
                self.currentDownloadTask = nil
                guard self.flowGate.beginInstallerHandoff() else {
                    self.flowGate.reset()
                    return
                }
                try await self.relaunchIntoInstaller(
                    with: newApp,
                    expectedVersion: manifest.version)
                // The installer process is now executing from this directory and owns its
                // cleanup. `exit` does not unwind defer blocks, so leave the source intact.
                preparedApp = nil
                // 只有脚本中的 `/usr/bin/open` 真正返回 0 后才退出当前 app。
                exit(0)
            } catch is CancellationError {
                DiagnosticLog.debug("OTA: download canceled by user")
                await MainActor.run {
                    progressWindow.close()
                    self.currentDownloadTask = nil
                    self.flowGate.reset()
                    // 静默取消（保留安装器阶段的 otaInstallCanceled 语义；下载取消无需额外提示）。
                }
            } catch {
                DiagnosticLog.debug("OTA: update FAILED: \(error)")
                await MainActor.run {
                    progressWindow.close()
                    self.currentDownloadTask = nil
                    self.flowGate.reset()
                    self.alert(title: L10n.otaDownloadFailed, message: L10n.otaDownloadFailedHint)
                }
            }
        }
        currentDownloadTask = task
    }

    /// 写 installerMode + 待安装路径，启动**新 app**进入安装器模式，然后退出当前进程。
    ///
    /// ## 关键修复（本次）：启动新 app，而不是重开旧 app。
    ///
    /// 历史实现启动的是 `Bundle.main.bundleURL`（即 /Applications/Plumb.app，**旧** app）。
    /// 这导致安装器逻辑跑的是**旧二进制**：旧版本里的安装器 bug（如 -2741 AppleScript
    /// 多行语法错误）会一直存在，旧版 app 永远无法自我更新——即使 appcast 指向的新版
    /// 已经修好了 bug，因为执行替换的根本不是新版。
    ///
    /// 现在：直接 `open` 已下载、已 sha256 校验、已解压的 **newApp**（临时位置的全新 bundle）。
    /// 新 app 以安装器模式启动 → 跑**自己**的安装器逻辑 → 把自己 cp 到 /Applications。
    /// 这样任何已修复的安装器代码都能立即生效，修复对旧版本是"自愈"的。
    ///
    /// 安装器 handoff 使用 argv（expectedVersion）；源固定为新进程自己的 Bundle.main。
    /// 这既消除了可写 defaults 路径的信任提升，也让未来签名过渡不受 cfprefsd 域漂移阻断。
    ///
    /// ## 重启机制（保留，经实测稳定）
    /// 用 shell 脚本执行 `open -n <newApp> --args ...`，并等待脚本真实退出码。只有 open
    /// 返回 0 才允许调用方退出；脚本写入、Process.run 或 open 失败都会保持当前 app 运行并提示。
    private func relaunchIntoInstaller(with newApp: URL, expectedVersion: String) async throws {
        let defaults = UserDefaults.standard
        // 新流程完全由 argv handoff 驱动。先清掉旧版兼容标志，避免签名相同的候选误走
        // 可写 UserDefaults 路径；installer 自身只信任正在运行的 Bundle.main。
        defaults.set(false, forKey: UpdateConfig.installerModeKey)
        defaults.removeObject(forKey: UpdateConfig.installerAppPathKey)

        do {
            try await UpdateInstallerCommand.launchAndObserveRelaunch(
                appPath: newApp.path,
                delaySeconds: 0,
                arguments: UpdateInstallerHandoff.commandLineArguments(
                    expectedVersion: expectedVersion))
        } catch {
            DiagnosticLog.debug("OTA: installer relaunch/open FAILED: \(error)")
            throw InstallError.relaunchFailed
        }
    }

    private func alert(title: String, message: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
