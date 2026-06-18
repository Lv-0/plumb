import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppDelegate
//
// 模块角色：应用生命周期与菜单栏 UI 的总装。
//
// 职责：
//   - 启动时创建状态栏菜单项（水滴图标）+ 菜单（立即居中 / 设置… / 权限… / 退出）。
//   - 装配 NSApp.mainMenu：accessory（LSUIElement）应用默认没有主菜单，⌘W/⌘Q 这类标准快捷键
//     无从派发；装配后「关闭窗口 ⌘W」「退出 ⌘Q」可用，打开设置（临时切到 .regular）时菜单栏也会出现。
//   - 申请屏幕录制与辅助功能权限；启动 WindowEventObserver 进入自动居中/平铺主循环。
//   - centerOnceOnLaunch：启动后短暂重试居中前台窗口（等待权限授予与窗口稳定）。
//   - 持有 SettingsWindowController 单例，按需弹出设置窗口。
//
// 与其它模块的边界：
//   不直接读写窗口几何——所有居中/平铺都委托给 centeringService（进而走
//   WindowEventObserver + WindowCenteringService）。本类只做 UI 与触发。
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let centeringService = WindowCenteringService()
    private let tilingSettingsStore = AppTilingSettingsStore()
    private lazy var eventObserver = WindowEventObserver(
        service: centeringService,
        tilingSettingsStore: tilingSettingsStore
    )
    private var statusItem: NSStatusItem?
    private var launchCenterTimer: DispatchSourceTimer?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()
        _ = ScreenCapturePermission.ensureAuthorized(prompt: true)
        _ = AccessibilityPermission.ensureTrusted(prompt: true)
        eventObserver.start()
        centerOnceOnLaunch()
    }

    @objc private func centerNow() {
        centerNowInternal(showAlertOnFailure: true, selectionPolicy: .focusedOnly)
    }

    private func centerNowInternal(showAlertOnFailure: Bool, selectionPolicy: WindowSelectionPolicy) {
        do {
            try centeringService.centerFrontmostWindow(selectionPolicy: selectionPolicy)
            // A successful center implies Accessibility is trusted. If trust was just granted
            // (common when the user clicked here after being prompted), kick the observer so
            // auto-centering activates without waiting for the next app switch.
            eventObserver.refreshAfterPossibleTrustChange()
        } catch {
            if let centeringError = error as? WindowCenteringError, centeringError == .fullscreenWindow {
                return
            }
            if showAlertOnFailure {
                showAlert(title: "窗口居中失败", message: error.localizedDescription)
            }
        }
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }

    @objc private func openScreenCaptureSettings() {
        ScreenCapturePermission.openSettings()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(store: tilingSettingsStore)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: 主菜单（让 ⌘W / ⌘Q 等标准快捷键可用）

    // 为何需要：Plumb 是 accessory（LSUIElement=true）应用，默认没有主菜单栏。⌘W（关闭窗口）、
    // ⌘Q（退出）这类标准快捷键由主菜单的 key equivalent 派发——没有 mainMenu，按下它们在设置
    // 窗口里完全无响应（既不能关窗口也不能退出）。这里装配一个最小主菜单：
    //   - App 菜单：关于 Plumb / 退出 Plumb（⌘Q → terminate:）
    //   - 文件菜单：关闭窗口（⌘W → performClose:，经响应链落到 key window）
    // accessory 应用本身不显示菜单栏；当打开设置临时切到 .regular 时，菜单栏才会出现——这正是一个
    // 带窗口 Mac 应用该有的样子。同时 key equivalent 在 accessory 态也会派发，故快捷键始终可用。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单（系统会把它的标题替换为应用名）。
        let appMenuItem = mainMenu.addItem(withTitle: "Plumb", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Plumb", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 Plumb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // 文件菜单：关闭窗口 ⌘W。target 留空 → 经响应链派发到 key window 的 performClose(_:)。
        let fileMenuItem = mainMenu.addItem(withTitle: "文件", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if
            let iconURL = Bundle.main.url(forResource: "StatusIconTemplate", withExtension: "png"),
            let statusImage = NSImage(contentsOf: iconURL)
        {
            statusImage.isTemplate = true
            statusImage.size = NSSize(width: 18, height: 18)
            item.button?.image = statusImage
            item.button?.imagePosition = .imageOnly
            item.button?.title = ""
        } else {
            item.button?.title = "Plumb"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        // 头部：应用名 + 副标题
        let header = menu.addItem(withTitle: "Plumb", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let subtitle = menu.addItem(withTitle: "  窗口居中 · 平铺", action: nil, keyEquivalent: "")
        subtitle.isEnabled = false
        menu.addItem(.separator())

        // 主操作：立即居中
        let centerItem = menu.addItem(withTitle: "立即居中", action: #selector(centerNow), keyEquivalent: "")
        centerItem.target = self
        centerItem.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)

        // 设置…
        let settingsItem = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)

        menu.addItem(.separator())

        let accItem = menu.addItem(withTitle: "辅助功能权限…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accItem.target = self
        accItem.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: nil)

        let scrItem = menu.addItem(withTitle: "屏幕录制权限…", action: #selector(openScreenCaptureSettings), keyEquivalent: "")
        scrItem.target = self
        scrItem.image = NSImage(systemSymbolName: "rectangle.dashed.badge.record", accessibilityDescription: nil)

        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "退出 Plumb", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)

        item.menu = menu
        statusItem = item
    }

    private func centerOnceOnLaunch() {
        // On launch, focus/permission prompts can delay when the "real" frontmost window is stable.
        // Retry for a short period without showing alerts.
        launchCenterTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var attempts = 0
        timer.schedule(deadline: .now() + 0.35, repeating: 0.45)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            attempts += 1

            // Don't burn attempts while the Accessibility permission is still pending;
            // the observer's awaitTrusted path will re-attach once it is granted, and this
            // timer keeps retrying so the very first window still gets centered.
            if !AccessibilityPermission.ensureTrusted(prompt: false) {
                if attempts >= 60 {
                    self.launchCenterTimer?.cancel()
                    self.launchCenterTimer = nil
                }
                return
            }

            if self.frontmostAppShouldTile() {
                return
            }
            self.centerNowInternal(showAlertOnFailure: false, selectionPolicy: .focusedOrAnyNonFullscreen)

            // Stop after a few seconds to avoid any "continuous" behavior.
            if attempts >= 10 {
                self.launchCenterTimer?.cancel()
                self.launchCenterTimer = nil
            }
        }
        launchCenterTimer = timer
        timer.resume()
    }

    private func frontmostAppShouldTile() -> Bool {
        let settings = tilingSettingsStore.load()
        guard settings.isEnabled else { return false }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return settings.shouldTile(bundleIdentifier: bundleID)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
