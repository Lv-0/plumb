import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateProgressWindow
//
// 模块角色：OTA 下载阶段的进度窗口。
//
// 职责：
//   - 显示"正在下载 Plumb %@…"、进度条（百分比）、已下载/总字节数。
//   - 提供 Cancel 按钮（点击触发 onCancel，由 Coordinator 取消下载 Task）。
//   - 服务器未返回 Content-Length 时降级为不确定动画。
//
// 设计说明：镜像 UpdateInstallerDelegate.setupWindow() 的 AppKit 命令式布局
// （360 宽 NSWindow，手动 frame），延续代码库"无 view-model、纯 AppKit"风格。
// 窗口在下载完成/取消/失败时由 Coordinator 主动 close()。
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class UpdateProgressWindow {
    /// 用户点击 Cancel 时触发（由 Coordinator 设置为取消下载 Task）。
    var onCancel: (() -> Void)?

    private let window: NSWindow
    private let messageLabel: NSTextField
    private let progressBar: NSProgressIndicator
    private let sizeLabel: NSTextField

    /// Cancel 按钮的 target。作为独立对象持有，确保按钮 weak target 不被释放，
    /// 点击时回调本窗口的 onCancel。比关联对象/映射表更直接。
    private let buttonTarget: ButtonActionTarget

    /// 是否为不确定模式（服务器未返回 Content-Length）。
    private var indeterminate = false

    init(version: String) {
        // 窗口：360×150，带标题栏（与 installer 窗口同宽，略高以容纳进度条+按钮）。
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = L10n.otaDownloadingTitle

        messageLabel = NSTextField(labelWithString: String(format: L10n.otaDownloadingMessage, version))
        messageLabel.alignment = .center
        messageLabel.frame = NSRect(x: 20, y: 110, width: 320, height: 20)

        progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: 78, width: 320, height: 20))
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        // 默认确定模式；updateProgress 会在 totalBytes<0 时切到不确定。

        sizeLabel = NSTextField(labelWithString: "")
        sizeLabel.alignment = .center
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeLabel.frame = NSRect(x: 20, y: 50, width: 200, height: 16)

        buttonTarget = ButtonActionTarget()
        let cancelButton = NSButton(title: L10n.otaCancel, target: buttonTarget, action: #selector(ButtonActionTarget.cancelClicked(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 270, y: 44, width: 70, height: 28)

        w.contentView?.addSubview(messageLabel)
        w.contentView?.addSubview(progressBar)
        w.contentView?.addSubview(sizeLabel)
        w.contentView?.addSubview(cancelButton)

        w.center()
        w.isReleasedWhenClosed = false
        window = w

        // 桥接：按钮点击 → 本窗口 onCancel。延迟赋值以捕获 self。
        buttonTarget.onAction = { [weak self] in self?.onCancel?() }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.orderOut(nil)
    }

    /// 由 Coordinator 在进度回调里调用（必须 MainActor）。
    /// - Parameters:
    ///   - bytesDownloaded: 已下载字节数。
    ///   - totalBytes: 总字节数；`< 0` 表示未知（切换为不确定动画）。
    func updateProgress(bytesDownloaded: Int64, totalBytes: Int64) {
        if totalBytes < 0 {
            if !indeterminate {
                indeterminate = true
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
            // 不确定模式下仍展示已下载量，让用户有反馈。
            sizeLabel.stringValue = formatBytes(bytesDownloaded)
            return
        }

        if indeterminate {
            // 从不确定切回确定（防御性：理论上单次下载内不会发生）。
            indeterminate = false
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
        }

        let percent = totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) * 100 : 0
        progressBar.doubleValue = min(max(percent, 0), 100)
        sizeLabel.stringValue = String(
            format: L10n.otaDownloadingSize,
            formatBytes(bytesDownloaded),
            formatBytes(totalBytes)
        )
    }

    // MARK: - 私有

    /// 把字节数格式化为人类可读的 "12.3 MB"（与 macOS Finder 一致，1000 进制）。
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }
}

/// Cancel 按钮的 target 桥。NSButton.target 是 weak 引用，需要独立存活的对象承接点击。
@MainActor
private final class ButtonActionTarget: NSObject {
    var onAction: (() -> Void)?

    @objc func cancelClicked(_ sender: NSButton) {
        onAction?()
    }
}
