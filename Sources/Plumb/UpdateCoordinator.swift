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
}

@MainActor
final class UpdateCoordinator {
    static let shared = UpdateCoordinator()

    private let checker = UpdateChecker()
    private let downloader = UpdateDownloader()

    private var osVersion: AppVersion {
        let raw = ProcessInfo.processInfo.operatingSystemVersion
        return AppVersion(major: raw.majorVersion, minor: raw.minorVersion, patch: raw.patchVersion)
    }

    /// 启动后台静默检查。失败完全静默（不打扰）；节流避免每次启动都请求。
    func checkForUpdatesInBackground() {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: UpdateConfig.lastCheckKey) as? Double,
           Date().timeIntervalSince1970 - last < UpdateConfig.backgroundCheckMinInterval {
            return // 节流：距离上次检查不足间隔，跳过。
        }
        defaults.set(Date().timeIntervalSince1970, forKey: UpdateConfig.lastCheckKey)

        Task { [weak self] in
            guard let self else { return }
            let result = await self.checker.check(current: AppVersion.current, osVersion: self.osVersion)
            await MainActor.run {
                if case .available(let manifest) = result {
                    self.notifyAvailable(manifest: manifest)
                }
                // 后台：upToDate / osTooOld / error 全部静默。
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
    private func startUpdate(manifest: UpdateManifest) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let zip = try await self.downloader.download(from: manifest.url)
                try self.downloader.verify(file: zip, expectedHex: manifest.sha256)
                let newApp = try self.downloader.unzip(zip)
                await MainActor.run {
                    self.relaunchIntoInstaller(with: newApp)
                }
            } catch {
                await MainActor.run {
                    self.alert(title: L10n.otaDownloadFailed, message: L10n.otaDownloadFailedHint)
                }
            }
        }
    }

    /// 写 installerMode + 待安装路径，以 Launch Services 重开自身，然后退出当前进程。
    ///
    /// 重要：必须用独立的 shell 进程（`/usr/bin/open`）启动新实例，而非 NSWorkspace.openApplication。
    /// 旧实现（及 completion-handler 版）从正在退出的 app 内部调用 openApplication：
    ///   - 旧版：openApplication 后立即 terminate，竞态 → -609 connectionInvalid
    ///   - completion 版：terminate 放在 completion 里仍被 macOS 取消（app 关闭序列会丢弃
    ///     自身的 LaunchServices 启动请求），新实例依然不启动
    /// 用 `/usr/bin/open` 经独立 shell 进程启动：该进程不归当前 app 管，terminate 当前 app
    /// 不会取消它，新实例可靠启动为安装器。延迟 0.4s 再 terminate，给 open 命令执行时间。
    private func relaunchIntoInstaller(with newApp: URL) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: UpdateConfig.installerModeKey)
        defaults.set(newApp.path, forKey: UpdateConfig.installerAppPathKey)
        // 关键：不能用 NSApp.terminate（会杀整个 session 包括子进程）也不能用 `open`（app 刚退出时
        // LaunchServices 静默忽略重启请求，返回 0 但不启动）。实测唯一可靠的方式：
        // 用 nohup + disown 启动一个独立 shell，sleep 后直接执行 app 二进制（绕过 LaunchServices），
        // 然后用 exit(0) 退出当前进程（exit 不发 session 清理信号，nohup 子进程能存活）。
        // 直接执行二进制而非 `open`：绕过 LS 的"刚退出的 app 不重启"机制，新实例真实启动为安装器。
        guard let execURL = Bundle.main.executableURL else { exit(0) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", #"nohup /bin/sh -c "sleep 1.0 && '\#(execURL.path)'" >/dev/null 2>&1 & disown"#]
        do {
            try proc.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                exit(0)
            }
        } catch {
            // 兜底：稍等后直接退出，安全网会处理 installerMode。
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
