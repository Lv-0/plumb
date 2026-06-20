import Foundation
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateInstaller
//
// 模块角色：安装器模式入口（installerMode 标志触发）。
//
// 职责：
//   - 极简 NSWindow 显示进度。
//   - 通过 NSAppleScript 的 `do shell script ... with administrator privileges` 提权执行
//     rm + cp -R 原子替换 /Applications/Plumb.app（弹系统密码框，一次）。
//   - 清零 installerMode 标志，以 Launch Services 启动新版本。
//
// 设计说明：主 app 退出后由本进程完成替换，避免"运行中二进制被覆盖"。
// 替换前 newApp 已通过 sha256 校验（由 Coordinator 保证）。
// 用 AppleScript 的 administrator privileges 而非已废弃的 AuthorizationExecuteWithPrivileges：
// 同样弹系统密码框，但 API 稳定、可正确回传子进程 exit code。
// 命令路径来自主 app 校验后的固定临时位置，不接受用户输入，提权最小化。
// ─────────────────────────────────────────────────────────────────────────────

enum InstallError: Error {
    case missingAppPath
    case authorizationDenied       // 用户取消密码框
    case replaceFailed(status: Int)
    case relaunchFailed
}

@MainActor
final class UpdateInstallerDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var statusLabel: NSTextField?

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
        do {
            try performInstall()
            finishAndRelaunch()
        } catch {
            fail(with: error)
        }
    }

    /// 提权原子替换 /Applications/Plumb.app。
    private func performInstall() throws {
        let defaults = UserDefaults.standard
        guard let srcPath = defaults.string(forKey: UpdateConfig.installerAppPathKey),
              FileManager.default.fileExists(atPath: srcPath) else {
            throw InstallError.missingAppPath
        }
        let dest = "/Applications/Plumb.app"
        // 固定脚本：rm -rf 旧 + cp -R 新。路径已校验，不接受用户输入。
        // 用单引号包裹路径；临时路径由 FileManager 生成不含单引号。
        let script = "rm -rf '\(dest)' && cp -R '\(srcPath)' '\(dest)'"
        let status = try runPrivileged(shellScript: script)
        guard status == 0 else { throw InstallError.replaceFailed(status: status) }

        // 替换成功后清零标志，避免下次启动误进入安装器。
        defaults.set(false, forKey: UpdateConfig.installerModeKey)
        defaults.removeObject(forKey: UpdateConfig.installerAppPathKey)
    }

    /// 通过 AppleScript 提权执行 shell 命令；用户取消密码框抛 authorizationDenied。
    /// 返回子进程 exit code。
    @discardableResult
    private func runPrivileged(shellScript: String) throws -> Int {
        // 转义脚本中的反斜杠与双引号，安全嵌入 AppleScript 字符串。
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        do shell script "\(escaped) ; echo $?"
        with administrator privileges
        """
        var errorInfo: NSDictionary?
        guard let result = NSAppleScript(source: appleScript)?.executeAndReturnError(&errorInfo) else {
            // 用户取消密码框 → errorInfo 含 NSAppleScriptErrorMessage 等。
            throw InstallError.authorizationDenied
        }
        // 解析 "echo $?" 输出的最后一行数字作为 exit code。
        let out = result.stringValue ?? ""
        let exitCode = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        return exitCode
    }

    private func finishAndRelaunch() {
        statusLabel?.stringValue = L10n.otaInstallDone
        let dest = URL(fileURLWithPath: "/Applications/Plumb.app")
        NSWorkspace.shared.openApplication(at: dest, configuration: .init()) { _, _ in
            exit(0)
        }
    }

    private func fail(with error: Error) {
        let msg: String
        switch error {
        case InstallError.authorizationDenied: msg = L10n.otaInstallCanceled
        case InstallError.missingAppPath: msg = L10n.otaInstallFailed
        case InstallError.replaceFailed: msg = L10n.otaInstallFailed
        case InstallError.relaunchFailed: msg = L10n.otaInstallFailed
        default: msg = L10n.otaInstallFailed
        }
        // 失败时也清零标志，避免下次启动误进入安装器。
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
