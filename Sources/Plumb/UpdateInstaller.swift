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

/// 安装命令的纯函数构造器。所有方法都不触网、不弹窗、不读盘，可单测。
enum UpdateInstallerCommand {
    /// 安装目标：固定为 /Applications/Plumb.app。
    static let destination = "/Applications/Plumb.app"

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
    static func resolveSourcePath(defaultsPath: String?, bundlePathFallback: String) -> String? {
        if let defaultsPath, !defaultsPath.isEmpty,
           FileManager.default.fileExists(atPath: defaultsPath) {
            return defaultsPath
        }
        // 新 app 自身就是源：bundlePathFallback 指向正在运行的（新）app bundle。
        if !bundlePathFallback.isEmpty,
           FileManager.default.fileExists(atPath: bundlePathFallback) {
            return bundlePathFallback
        }
        return nil
    }

    /// 构造提权替换的 shell 命令：`rm -rf '<dest>' && cp -R '<src>' '<dest>'`。
    /// 路径来自已校验位置（resolveSourcePath），不接受外部输入；用 shell 单引号包裹。
    static func buildShellScript(source: String, destination: String = destination) -> String {
        "rm -rf \(shellQuoted(destination)) && cp -R \(shellQuoted(source)) \(shellQuoted(destination))"
    }

    /// POSIX shell 单引号转义。`'` 需要结束当前字符串、写入转义单引号、再重新进入单引号。
    static func shellQuoted(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
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
        // 源路径解析：优先用 coordinator 写入的临时解压路径；缺失则回退到当前
        // 进程自身的 bundle 路径（coordinator 现在直接启动新 app 进安装器模式，
        // 此时 Bundle.main 就是新 app）。
        guard let srcPath = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: defaults.string(forKey: UpdateConfig.installerAppPathKey),
            bundlePathFallback: Bundle.main.bundlePath
        ) else {
            throw InstallError.missingAppPath
        }
        let shellScript = UpdateInstallerCommand.buildShellScript(source: srcPath)
        let status = try runPrivileged(shellScript: shellScript)
        guard status == 0 else { throw InstallError.replaceFailed(status: status) }

        // 替换成功后清零标志，避免下次启动误进入安装器。
        defaults.set(false, forKey: UpdateConfig.installerModeKey)
        defaults.removeObject(forKey: UpdateConfig.installerAppPathKey)
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
