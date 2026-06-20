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
    private func relaunchIntoInstaller(with newApp: URL) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: UpdateConfig.installerModeKey)
        defaults.set(newApp.path, forKey: UpdateConfig.installerAppPathKey)
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        NSApp.terminate(nil)
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
