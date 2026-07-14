import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SettingsWindowController
//
// 模块角色：设置窗口的 AppKit 外壳（NSWindowController）。
//
// 职责：
//   - 构造一个无标题栏、可拖拽、带液态玻璃材质（macOS 26 NSGlassEffectView，
//     低版本回退 NSVisualEffectView）的 NSWindow。
//   - 用 NSHostingController 承载 SwiftUI 的 SettingsView，并把它嵌入
//     NSGlassEffectView.contentView——这是官方集成方式，使折射/lensing/边缘高光作用于
//     整窗（含边缘），而非把 SwiftUI 平铺在不参与折射的同层背景之上。
//   - showWindow 时做缩放+淡入出现动画，并向 SettingsView 发 windowDidShow 通知，
//     使缓存的视图能重新扫描已安装应用（AppDelegate 把本控制器缓存为单例，再次打开
//     不会重触发 .task，故依赖该通知驱动刷新）。
// ─────────────────────────────────────────────────────────────────────────────

/// 设置窗口壳：NSWindow + NSGlassEffectView（SwiftUI 内容嵌入其 contentView）。
/// 液态玻璃由 NSGlassEffectView 提供（动态折射/边缘高光），SwiftUI 内容保持透明叠加在玻璃内部。
@MainActor
final class SettingsWindowController: NSWindowController {
    private let store: AppTilingSettingsStore

    init(store: AppTilingSettingsStore) {
        self.store = store

        // 自定义窗口子类：强制 isOpaque=false + backgroundColor=.clear + 可成为 key/main。
        // 关键：标准 .titled 窗口即便设了 backgroundColor=.clear，主题仍会画一层不透明背景，
        // 把 NSGlassEffectView 的折射压成灰板。只有让窗口“什么都不画”，玻璃才能采样窗口后方
        // 的桌面/内容做动态折射（晶莹液态玻璃，而非毛玻璃）。
        let window = LiquidGlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.settings
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 760, height: 520)
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.center()

        // macOS 26 液态玻璃：NSGlassEffectView 作为窗口 contentView，SwiftUI 用 NSHostingView
        // 嵌入 glass.contentView（按官方/onmyway133 指南的成熟模式）。
        // 关键：window.backgroundColor = .clear（已在上方设置）必需，否则窗口会在玻璃上
        // 绘制自己的不透明背景，把折射压成实心面板。glass.clipsToBounds 裁圆角。
        let rootView = SettingsView(store: store)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 20
            // 折射拉满：tint=nil（完全不染色），折射完全由窗口后方内容驱动，
            // 玻璃质感最强。任何 tint 都会削弱折射，故“最高液态玻璃”=无 tint。
            glass.tintColor = nil
            glass.clipsToBounds = true
            let host = NSHostingView(rootView: rootView)
            // hosting view 必须透明，否则会盖住玻璃折射。
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            glass.contentView = host
            window.contentView = glass

            // 顶部 lensing 高光拉满：液态玻璃最明显的特征是边缘折光高光。
            // 用一条较强的白色渐变贴在玻璃顶部边缘，让窗口在任何背景下都呈现明显的“玻璃浮起”感。
            if let glassLayer = glass.layer {
                let highlight = CAGradientLayer()
                highlight.frame = glass.bounds
                highlight.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                highlight.colors = [
                    NSColor(calibratedWhite: 1.0, alpha: 0.45).cgColor,
                    NSColor(calibratedWhite: 1.0, alpha: 0.0).cgColor
                ]
                highlight.locations = [0, 0.18]
                highlight.startPoint = CGPoint(x: 0.5, y: 1.0)
                highlight.endPoint = CGPoint(x: 0.5, y: 0.0)
                glassLayer.addSublayer(highlight)
                _ = glassLayer
            }
        } else {
            // 低版本回退：NSVisualEffectView 只能给毛玻璃近似，无真折射。
            let v = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 880, height: 600))
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            let host = NSHostingView(rootView: rootView)
            host.frame = v.bounds
            host.autoresizingMask = [.width, .height]
            v.addSubview(host)
            window.contentView = v
        }

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        // 出现动画：缩放（0.96→1.0）+ 淡入，easeOut。
        // 关键：缩放改变 size 时会让窗口 origin 漂移（AppKit 以非中心锚点扩展），且 .accessory→.regular
        // 切换 + 液态玻璃面板 resize 会进一步扰动位置。若依赖 AX observer 的异步居中 retry，会与此处
        // 动画竞争（实测窗口最终停在偏上 112px、看似“没居中”）。改为动画结束后在 completionHandler 里
        // 一次性精确居中：此时 size 已稳定为最终尺寸，setFrameOrigin 直接落到屏幕可见区正中。
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
            }, completionHandler: { [weak self] in
                // 动画结束、size 稳定后精确居中（消除缩放引入的 origin 漂移）。
                MainActor.assumeIsolated {
                    self?.centerOnCurrentScreen()
                }
            })
        }

        // 关键：本应用是菜单栏 accessory app（.accessory），其窗口默认无法成为真正的 key window。
        // 而 NSGlassEffectView 只有在“key 且 active”的窗口里才会渲染折射（晶莹液态玻璃），
        // 否则退化成不透明灰板。因此显示设置窗口时临时切到 .regular，让窗口能真正成为 key/active，
        // 使液态玻璃激活。NSGlassPanel 已覆写 canBecomeKey/canBecomeMain 配合。
        // 窗口关闭时会在 windowWillClose(_:) 切回 .accessory，避免 Plumb 图标长期驻留 Dock。
        window?.delegate = self
        NSApp.setActivationPolicy(.regular)
        // windowWillClose 关闭窗口后会用 hide(_:) 让 Plumb 退回后台；这里（重开设置时）先取消隐藏，
        // 配合下方 activate + makeKeyAndOrderFront 把窗口重新带到前台。
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        // 通知设置视图：窗口已显示。
        // 原因：本控制器被 AppDelegate 缓存为单例，每次"打开设置"复用同一个 SettingsView，
        // 其 `.task` 仅在首次出现时执行一次 → 再次打开不会重新扫描已安装应用，
        // 导致新安装的应用在退出 App 前不可见。视图收到本通知后会重新拉取应用列表。
        NotificationCenter.default.post(name: SettingsWindowNotifications.windowDidShow, object: nil)
    }

    /// 把设置窗口精确放到当前屏幕可见区正中（动画结束后调用，消除缩放引入的 origin 漂移）。
    /// 用 setFrameOrigin 一次写入（非动画），避免与 AX observer 的异步居中竞争。
    private func centerOnCurrentScreen() {
        guard let window else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        guard visible.width > 0, visible.height > 0 else { return }
        let frame = window.frame
        let x = visible.minX + (visible.width - frame.width) / 2
        let y = visible.minY + (visible.height - frame.height) / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // 切回 .accessory：showWindow 里临时切到 .regular 激活了液态玻璃折射，
        // 但 .regular 会让 Plumb 在 Dock 显示图标。仅 setActivationPolicy(.accessory) 在 App 仍处
        // 前台激活态时，Dock 图标往往不会立即移除（会残留）。因此切回 accessory 后再 hide(_:)，
        // 让 Plumb 退出前台、把焦点交还给用户原先在用的应用，Dock 图标随之立即消失，
        // 回到“纯菜单栏应用”（与 LSUIElement=true 一致）。
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }
}

/// 液态玻璃面板：自定义 NSWindow 子类，强制透明并允许成为 key/main。
///
/// 为什么需要子类：标准 `.titled` 窗口即便设了 `backgroundColor = .clear`，主题系统仍会在
/// contentView 之下绘制一层不透明背景，把 `NSGlassEffectView` 的折射压成均匀灰板（毛玻璃/实心）。
/// 真正的液态玻璃（折射后方内容）要求窗口“完全不绘制自身背景”，只剩玻璃层。本子类通过：
///   - `isOpaque` 恒返回 false；
///   - `backgroundColor` 恒返回 `.clear`；
///   - `canBecomeKey`/`canBecomeMain` 返回 true（配合 `.borderless` 让无标题栏窗口仍可成为 key window）。
/// 从而让 `NSGlassEffectView` 能采样窗口后方的桌面/内容做动态折射。
private final class LiquidGlassPanel: NSWindow {
    override var isOpaque: Bool {
        get { false }
        set { _ = newValue }   // 忽略外部设置，始终非不透明
    }
    override var backgroundColor: NSColor? {
        get { .clear }
        set { _ = newValue }   // 忽略外部设置，始终透明
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
