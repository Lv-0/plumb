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
    static func buildScript(appPath: String, delaySeconds: Int = 2) -> String {
        "#!/bin/bash\nsleep \(delaySeconds)\n/usr/bin/open -n -- \(UpdateInstallerCommand.shellQuoted(appPath))\n"
    }
}

@MainActor
final class UpdateCoordinator {
    static let shared = UpdateCoordinator()

    private let checker: UpdateChecker
    private let downloader: UpdateDownloader

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
        runSilentCheck()
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
        runSilentCheck()
    }

    /// 静默发起一次检查：发现更新 → notifyAvailable；upToDate/osTooOld/error 全部静默。
    /// 后台与「打开设置」两条自动路径共用此实现，差别只在节流策略（调用方各自处理）。
    private func runSilentCheck() {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.checker.check(current: AppVersion.current, osVersion: self.osVersion)
            await MainActor.run {
                if case .available(let manifest) = result {
                    self.notifyAvailable(manifest: manifest)
                }
                // 静默：upToDate / osTooOld / error 全部不打扰。
            }
        }
    }

    /// 手动检查。失败弹窗提示（不阻塞 app）。
    func checkForUpdatesManually() {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.checker.check(current: AppVersion.current, osVersion: self.osVersion)
            await MainActor.run {
                switch result {
                case .available(let manifest):
                    self.notifyAvailable(manifest: manifest)
                case .upToDate:
                    self.alert(title: L10n.otaUpToDate, message: "")
                case .osTooOld:
                    // 手动也不提示无法安装的版本（静默）。
                    self.alert(title: L10n.otaUpToDate, message: "")
                case .error:
                    self.alert(title: L10n.otaCheckFailed, message: L10n.otaCheckFailedHint)
                }
            }
        }
    }

    /// 展示"有新版本"提示，用户确认后走完整下载+安装流程。
    private func notifyAvailable(manifest: UpdateManifest) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: L10n.otaNewVersionTitle, manifest.version)
        alert.informativeText = manifest.notes(for: AppLanguage.current)
        alert.addButton(withTitle: L10n.otaUpdateNow)
        alert.addButton(withTitle: L10n.otaCancel)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return } // 用户取消
        startUpdate(manifest: manifest)
    }

    /// 下载 → 校验 → 解压 → 写标志 → 重开自身进入安装器。
    ///
    /// 下载阶段弹出进度窗口（百分比 + 字节数 + Cancel）。
    /// 用户点 Cancel → 取消下载 Task → downloader 抛 CancellationError → 静默关闭窗口。
    private func startUpdate(manifest: UpdateManifest) {
        DiagnosticLog.debug("OTA: update confirmed by user, target=\(manifest.version) starting download")

        let progressWindow = UpdateProgressWindow(version: manifest.version)
        progressWindow.onCancel = { [weak self] in
            // 协作式取消：downloader.download 会抛 CancellationError。
            self?.currentDownloadTask?.cancel()
        }
        progressWindow.show()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let zip = try await self.downloader.download(from: manifest.url) { downloaded, total in
                    // downloader 回调线程不保证；切回 MainActor 更新 UI。
                    Task { @MainActor in
                        progressWindow.updateProgress(bytesDownloaded: downloaded, totalBytes: total)
                    }
                }
                DiagnosticLog.debug("OTA: downloaded \(manifest.version)")
                try self.downloader.verify(file: zip, expectedHex: manifest.sha256)
                DiagnosticLog.debug("OTA: sha256 verified")
                let newApp = try self.downloader.unzip(zip)
                DiagnosticLog.debug("OTA: unzipped → \(newApp.path), relaunching into installer")
                await MainActor.run {
                    progressWindow.close()
                    self.relaunchIntoInstaller(with: newApp)
                }
            } catch is CancellationError {
                DiagnosticLog.debug("OTA: download canceled by user")
                await MainActor.run {
                    progressWindow.close()
                    // 静默取消（保留安装器阶段的 otaInstallCanceled 语义；下载取消无需额外提示）。
                }
            } catch {
                DiagnosticLog.debug("OTA: update FAILED: \(error)")
                await MainActor.run {
                    progressWindow.close()
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
    /// 仍把 newApp.path 写进 UserDefaults 作为冗余源路径（向后兼容 + 双保险）；
    /// 安装器侧 (UpdateInstallerCommand.resolveSourcePath) 优先读它，缺失时回退到
    /// Bundle.main.bundlePath（新 app 启动后即等于 newApp.path）。
    ///
    /// ## 重启机制（保留，经实测稳定）
    /// 用独立 shell 脚本 `sleep; open -n <newApp>` 启动：脚本作为独立进程，
    /// 当前 app exit(0) 不会取消它；`-n` 强制 LaunchServices 开新实例（即便旧 app
    /// 还在退出序列中也照开）。delay 给旧 app 留出退出时间，避免新旧实例同时持有
    /// /Applications/Plumb.app 导致 cp 冲突。
    private func relaunchIntoInstaller(with newApp: URL) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: UpdateConfig.installerModeKey)
        defaults.set(newApp.path, forKey: UpdateConfig.installerAppPathKey)

        // 写一个独立 shell 脚本到临时位置，内容是 `sleep; open -n <newApp>`。
        // 用 Process 启动这个脚本（重定向 stdio 到 /dev/null），脚本作为独立进程运行，
        // 不受当前 app 的 NSApplication session 约束。当前 app exit(0) 后，脚本继续执行 open，
        // LaunchServices 从这个独立进程收到 open 请求，能正常启动新 app（有完整 GUI 会话，
        // 安装器的密码框能正常显示）。
        //
        // 之前失败的方案（都不可靠）：
        //   - NSWorkspace.openApplication + terminate → -609 connectionInvalid
        //   - openApplication completion handler → 仍被 terminate 取消
        //   - nohup 直接执行二进制 → 能启动但无 GUI 会话，密码框不显示
        //   - nohup + open → app 的子 session，LS 拒绝
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-relaunch-\(UUID().uuidString).sh")
        // 用 -n 强制新实例；sleep 2 给当前 app 充分时间退出（避免新旧同时占用 /Applications）。
        let script = UpdateRelaunchCommand.buildScript(appPath: newApp.path)
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            // 设可执行权限
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            exit(0)
        }
        let proc = Process()
        proc.executableURL = scriptURL
        proc.standardInput = FileHandle(forWritingAtPath: "/dev/null")
        proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try proc.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                exit(0)
            }
        } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                exit(0)
            }
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
