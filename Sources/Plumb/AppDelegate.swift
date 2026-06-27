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
    private let dmgMonitor = DmgMountMonitor()
    private lazy var eventObserver = WindowEventObserver(
        service: centeringService,
        tilingSettingsStore: tilingSettingsStore,
        dmgMonitor: dmgMonitor
    )
    private var statusItem: NSStatusItem?
    private var launchCenterTimer: DispatchSourceTimer?
    private var settingsWindowController: SettingsWindowController?

    /// 逃生口（菜单栏图标隐藏时）的「连续两次打开」判定器。
    /// 若距上次打开 ≤ threshold 秒即视为「连续两次打开」→ 弹出设置；超过则重新计数。
    /// 纯逻辑状态机（无 macOS 依赖），threshold 与计数细节见 `ReopenDetector`（可单测）。
    ///
    /// 信号选型（实测结论）：菜单栏图标隐藏后 Plumb 是纯后台 agent（无 Dock 图标 / 无菜单栏
    /// 图标 / 无窗口）。此时经 Finder/启动台/Spotlight 再次打开，系统走 LaunchServices 路径
    /// 投递 `applicationShouldHandleReopen`（每次打开都投递，hasVisibleWindows=false）——这是
    /// 唯一对「隐藏 agent 的再次打开」可靠的系统信号。
    /// ⚠️ 历史教训：v2.0.10–v2.0.12 误判此信号无效，是因为只测了 CLI `open`（走另一条路径、
    /// 对隐藏 agent 不投递）。Finder 双击走 LaunchServices，该信号每次必触发。务必用真实
    /// LaunchServices 路径验证，不要用 CLI `open`。
    private var reopenDetector = ReopenDetector()

    /// 监听「隐藏菜单栏图标」开关变化的观察者。
    /// AppDelegate 与 app 同生命周期，无需显式移除（闭包用 [weak self]，无循环引用）。
    private var statusBarVisibilityObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 按设置决定是否显示菜单栏图标：默认显示；开启「隐藏菜单栏图标」则不创建。
        if !tilingSettingsStore.load().hideStatusBarIcon {
            showStatusBarIcon()
        }
        setupMainMenu()
        observeStatusBarVisibilityChanges()
        _ = ScreenCapturePermission.ensureAuthorized(prompt: true)
        _ = AccessibilityPermission.ensureTrusted(prompt: true)
        dmgMonitor.start()
        eventObserver.start()
        centerOnceOnLaunch()
        UpdateCoordinator.shared.checkForUpdatesInBackground()
    }

    // MARK: 菜单栏图标隐藏时的逃生口（连续两次打开 → 弹设置）

    /// 经 Finder/启动台/Spotlight「再次打开」已运行的 Plumb 时触发。对隐藏图标的 agent app，
    /// 这是唯一可靠的「再次打开」系统信号（每次打开都投递，hasVisibleWindows=false）。
    ///
    /// 当菜单栏图标被隐藏、用户无从进入设置时，**连续两次打开（间隔 ≤ threshold 秒）** 即弹出
    /// 设置，这是隐藏后回到设置的唯一入口。图标可见时走默认行为（不计数、不弹窗）。
    /// 计数与时间窗口判定委托给 `ReopenDetector`（纯逻辑，单测覆盖）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard tilingSettingsStore.load().hideStatusBarIcon else { return true }
        // registerOpen 记录本次打开并判定：true = 距上次打开在窗口内 → 连续两次，弹设置。
        if reopenDetector.registerOpen() {
            openSettings()
        }
        return true
    }

    /// 监听设置 UI 的「隐藏菜单栏图标」开关变化：拨动后即时增/删状态栏图标。
    /// 用通知解耦——设置视图不持有 AppDelegate（windowDidShow 通知亦是此先例）。
    private func observeStatusBarVisibilityChanges() {
        statusBarVisibilityObserver = NotificationCenter.default.addObserver(
            forName: SettingsWindowNotifications.statusBarIconVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyStatusBarVisibility()
            }
        }
    }

    /// 按当前设置增/删菜单栏图标（开关变化时调用）。
    private func applyStatusBarVisibility() {
        let shouldHide = tilingSettingsStore.load().hideStatusBarIcon
        if shouldHide {
            hideStatusBarIcon()
        } else {
            showStatusBarIcon()
        }
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
                showAlert(title: L10n.centerFailedTitle, message: error.localizedDescription)
            }
        }
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

    @objc private func checkForUpdates() {
        UpdateCoordinator.shared.checkForUpdatesManually()
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
        appMenu.addItem(withTitle: L10n.about, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L10n.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // 文件菜单：关闭窗口 ⌘W。target 留空 → 经响应链派发到 key window 的 performClose(_:)。
        let fileMenuItem = mainMenu.addItem(withTitle: L10n.fileMenu, action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L10n.fileMenu)
        fileMenu.addItem(withTitle: L10n.closeWindow, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }

    private func showStatusBarIcon() {
        // 幂等：图标已存在则不重复创建（避免开关来回拨动时叠加多个图标）。
        if statusItem != nil { return }
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

        // 主操作：立即居中
        let centerItem = menu.addItem(withTitle: L10n.centerNow, action: #selector(centerNow), keyEquivalent: "")
        centerItem.target = self
        centerItem.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)

        // 设置…
        let settingsItem = menu.addItem(withTitle: L10n.settings, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)

        // 检查更新…
        let updateItem = menu.addItem(withTitle: L10n.otaCheckForUpdates, action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)

        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: L10n.quitApp, action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)

        item.menu = menu
        statusItem = item
    }

    /// 从状态栏移除水滴图标（「隐藏菜单栏图标」开启或切换时调用）。
    private func hideStatusBarIcon() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
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
