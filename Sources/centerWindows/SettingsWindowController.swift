import AppKit
import SwiftUI

/// 瘦身后的设置窗口壳：只负责 NSWindow 与 NSHostingController 承载 SwiftUI 内容。
/// Liquid Glass 由 SwiftUI 视图自身（NavigationSplitView 侧边栏）+ 窗口透明材质实现。
@MainActor
final class SettingsWindowController: NSWindowController {

    private let store: AppTilingSettingsStore

    init(store: AppTilingSettingsStore) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 760, height: 520)
        window.isOpaque = false
        window.center()

        let hosting = NSHostingController(rootView: SettingsView(store: store))
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
    }
}
