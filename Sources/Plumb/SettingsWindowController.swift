import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SettingsWindowController
//
// 模块角色：设置窗口的 AppKit 外壳（NSWindowController）。
//
// 职责：
//   - 构造一个无标题栏、可拖拽、带 Liquid Glass 材质（macOS 26 NSGlassEffectView，
//     低版本回退 NSVisualEffectView）的 NSWindow。
//   - 用 NSHostingController 承载 SwiftUI 的 SettingsView，透明叠加在玻璃背景之上。
//   - showWindow 时做缩放+淡入出现动画，并向 SettingsView 发 windowDidShow 通知，
//     使缓存的视图能重新扫描已安装应用（AppDelegate 把本控制器缓存为单例，再次打开
//     不会重触发 .task，故依赖该通知驱动刷新）。
// ─────────────────────────────────────────────────────────────────────────────

/// 设置窗口壳：NSWindow + NSGlassEffectView 背景 + NSHostingController 承载 SwiftUI 内容。
/// 窗口整体（含边缘）呈现 Liquid Glass 材质；SwiftUI 内容透明叠加其上。
@MainActor
final class SettingsWindowController: NSWindowController {

    private let store: AppTilingSettingsStore

    init(store: AppTilingSettingsStore) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 760, height: 520)
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.center()

        guard let contentView = window.contentView else { super.init(window: window); return }

        // 整窗 Liquid Glass 背景：macOS 26 的 NSGlassEffectView（若不可用则回退 NSVisualEffectView）。
        let glassBackground: NSView = {
            if #available(macOS 26.0, *) {
                let v = NSGlassEffectView(frame: .zero)
                // 给玻璃层一个柔和的底色，使其读起来是“磨砂玻璃”而非近乎全透明。
                v.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55)
                return v
            } else {
                let v = NSVisualEffectView(frame: .zero)
                v.material = .hudWindow
                v.blendingMode = .behindWindow
                v.state = .active
                return v
            }
        }()
        glassBackground.translatesAutoresizingMaskIntoConstraints = false
        glassBackground.wantsLayer = true
        glassBackground.layer?.cornerRadius = 16
        contentView.addSubview(glassBackground, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            glassBackground.topAnchor.constraint(equalTo: contentView.topAnchor),
            glassBackground.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            glassBackground.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            glassBackground.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        // SwiftUI 内容透明叠加在玻璃背景之上。
        let hosting = NSHostingController(rootView: SettingsView(store: store))
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentViewController = hosting

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        // 出现动画：缩放（0.96→1.0）+ 淡入，easeOut。
        window?.alphaValue = 0
        if let frame = window?.frame {
            let scaled = NSRect(
                origin: frame.origin,
                size: NSSize(width: frame.width * 0.96, height: frame.height * 0.96)
            )
            window?.setFrame(scaled, display: true, animate: false)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window?.animator().alphaValue = 1
                window?.animator().setFrame(frame, display: true)
            })
        }
        NSApp.activate(ignoringOtherApps: true)

        // 通知设置视图：窗口已显示。
        // 原因：本控制器被 AppDelegate 缓存为单例，每次"打开设置"复用同一个 SettingsView，
        // 其 `.task` 仅在首次出现时执行一次 → 再次打开不会重新扫描已安装应用，
        // 导致新安装的应用在退出 App 前不可见。视图收到本通知后会重新拉取应用列表。
        NotificationCenter.default.post(name: SettingsWindowNotifications.windowDidShow, object: nil)
    }
}
