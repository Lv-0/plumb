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
//   - 持有 SettingsWindowController 单例，按需弹出设置窗口。
//
// 与其它模块的边界：
//   不直接读写窗口几何——所有居中/平铺都委托给 centeringService（进而走
//   WindowEventObserver + WindowCenteringService）。本类只做 UI 与触发。
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Fresh status-item identity for the macOS 26 ControlCenter-hosted menu-bar item.
    /// Older/local builds could leave corrupted trackedApplications ownership under the
    /// original identity; using a stable v2 name gives the menu item a clean slot.
    private static let statusItemAutosaveName = "com.comet.plumb.statusItem.v2"

    // NSMenuDelegate：状态栏菜单打开前（menuNeedsChange）刷新两个总开关的勾选标记，
    // 让用户从菜单栏即可看到当前开/关状态。menu.autoenablesItems=false 时 AppKit 不再调用
    // validateMenuItem，故改用 menuNeedsChange 这条与开关无关的刷新路径。
    private let centeringService = WindowCenteringService()
    private let tilingSettingsStore = AppTilingSettingsStore()
    private let dmgMonitor = DmgMountMonitor()
    private lazy var eventObserver = WindowEventObserver(
        service: centeringService,
        tilingSettingsStore: tilingSettingsStore,
        dmgMonitor: dmgMonitor
    )
    private var statusItem: NSStatusItem?
    private var statusIconHealthTimer: DispatchSourceTimer?
    private var settingsWindowController: SettingsWindowController?

    /// 后台「自动检查更新」定期定时器。
    /// Plumb 是菜单栏常驻 agent，启动检查只在 applicationDidFinishLaunching 跑一次；
    /// 本定时器在 app 长驻期间每 backgroundCheckMinInterval（6h）静默检查一次，
    /// 让运行很久不重启的用户也能收到更新提示。随 app 生命周期，无需显式 invalidate。
    private var backgroundUpdateTimer: DispatchSourceTimer?

    /// 「连续两次打开 → 弹出设置」逃生口的判定器（无条件生效，不再限于图标隐藏时）。
    /// 若距上次打开 ≤ threshold 秒即视为「连续两次打开」→ 弹出设置；超过则重新计数。
    /// 纯逻辑状态机（无 macOS 依赖），threshold 与计数细节见 `ReopenDetector`（可单测）。
    ///
    /// 信号选型（实测结论）：Plumb 是无 Dock 图标的 agent。经 Finder/启动台/Spotlight 再次
    /// 打开时，系统走 LaunchServices 路径投递 `applicationShouldHandleReopen`（每次打开都投递，
    /// hasVisibleWindows=false）——这是唯一对「agent 的再次打开」可靠的系统信号。
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
            scheduleStatusIconHealthChecks()
        }
        // macOS 26 的菜单栏项由 Control Center 托管。先把 NSStatusItem 交给系统一个
        // runloop 周期完成注册，再启动权限探测、AX observer、更新检查等可能触发窗口/进程
        // 切换的工作；否则状态栏项可能只停留在本进程的占位窗口，未进入实际菜单栏窗口栈。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.finishLaunchingAfterStatusIconRegistration()
        }
    }

    private func finishLaunchingAfterStatusIconRegistration() {
        setupMainMenu()
        observeStatusBarVisibilityChanges()
        _ = ScreenCapturePermission.ensureAuthorized(prompt: true)
        _ = AccessibilityPermission.ensureTrusted(prompt: true)
        dmgMonitor.start()
        // WindowEventObserver is the sole owner of automatic startup layout. It already
        // attaches to the frontmost app, waits for permission, retries unstable windows,
        // and owns self-layout grace/manual-move classification.
        eventObserver.start()
        // 注入「自动检查更新」开关判定闭包：读 settings.autoCheckUpdates。
        // 之后所有自动检查路径（启动、后台定时器、打开设置）经此统一判定，关闭时全部跳过。
        UpdateCoordinator.shared.autoCheckUpdatesProvider = { [tilingSettingsStore] in
            tilingSettingsStore.load().autoCheckUpdates
        }
        UpdateCoordinator.shared.checkForUpdatesInBackground()
        scheduleBackgroundUpdateChecks()
    }

    /// 启动后台「自动检查更新」定期定时器：每 6h（backgroundCheckMinInterval）静默检查一次。
    /// 复用 UpdateCoordinator.checkForUpdatesInBackground()：自带开关判定与节流（避免与启动检查、
    /// 打开设置检查重复请求）。系统休眠期间 DispatchSourceTimer 暂停，唤醒后由启动/打开设置检查补位。
    private func scheduleBackgroundUpdateChecks() {
        backgroundUpdateTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + UpdateConfig.backgroundCheckMinInterval,
            repeating: UpdateConfig.backgroundCheckMinInterval
        )
        timer.setEventHandler { [weak self] in
            self?.triggerBackgroundUpdateCheck()
        }
        backgroundUpdateTimer = timer
        timer.resume()
    }

    /// 定时器触发的后台检查入口（独立方法便于弱引用调用）。
    private func triggerBackgroundUpdateCheck() {
        UpdateCoordinator.shared.checkForUpdatesInBackground()
    }

    // MARK: 逃生口（连续两次打开 → 弹设置）+ 状态栏图标自愈

    /// 经 Finder/启动台/Spotlight「再次打开」已运行的 Plumb 时触发。对无 Dock 图标的 agent app，
    /// 这是唯一可靠的「再次打开」系统信号（每次打开都投递，hasVisibleWindows=false）。
    ///
    /// **连续两次打开（间隔 ≤ threshold 秒）→ 无条件弹出设置。**
    /// 早期版本仅在「隐藏菜单栏图标」开启时才启用此逃生口；结果当图标因环境原因不可见时
    /// （菜单栏图标过多被挤掉 / 刘海屏遮挡 / macOS 26 状态栏托管场景不渲染——设置仍是「显示」），
    /// 用户既看不到图标、双开也不弹设置，被彻底锁在设置之外（2026-07 实测踩坑）。故改为无条件：
    /// 双开已运行的 app 是明确的「给我界面」手势；图标可见时多弹一次设置也无副作用（关掉即可）。
    /// 计数与时间窗口判定委托给 `ReopenDetector`（纯逻辑，单测覆盖）。
    ///
    /// 顺带自愈：每次 reopen 都检查「设置要求显示但图标实际不可见」的情况并重建图标。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        healStatusBarIconIfNeeded()
        // registerOpen 记录本次打开并判定：true = 距上次打开在窗口内 → 连续两次，弹设置。
        if reopenDetector.registerOpen() {
            DiagnosticLog.debug("reopen: double-open within \(Int(ReopenDetector.threshold))s — opening settings")
            openSettings()
        }
        return true
    }

    /// 设置要求显示图标、但图标不存在或其状态栏窗口缺失/不可见时，销毁重建（重新注册托管场景）。
    ///
    /// 重建指纹刻意保守：仅 `button.window == nil` 或 `isVisible == false`。
    /// ⚠️ 不要用 occlusionState / windowFrame 作为重建条件——2026-07 实测：macOS 26 起状态栏
    /// 项的像素由 ControlCenter 托管渲染，app 侧的状态栏窗口即使在图标正常显示时也停在屏幕
    /// 右下角「停车位」（本机实测 frame=(1478,960,34,22)、occluded=true；iStat 等第三方项同样
    /// 如此）。若据此重建，健康图标每次 reopen 都会被销毁重建（闪烁 + 用户手排的图标顺序丢失）。
    /// frame/occluded 仅作取证日志：真被菜单栏挤掉（图标过多/刘海屏）与托管场景不渲染时，
    /// 这些字段的组合是事后区分两类问题的关键证据。
    private func healStatusBarIconIfNeeded() {
        guard !tilingSettingsStore.load().hideStatusBarIcon else { return }
        guard let item = statusItem else {
            DiagnosticLog.debug("statusIcon: health-check — item missing, creating")
            showStatusBarIcon()
            if statusIconHealthTimer == nil {
                scheduleStatusIconHealthChecks()
            }
            return
        }
        let win = item.button?.window
        let frameDesc = win.map { "\($0.frame)" } ?? "nil"
        let occluded = win.map { !$0.occlusionState.contains(.visible) } ?? true
        DiagnosticLog.debug("statusIcon: health-check autosave=\(item.autosaveName ?? "nil") itemVisible=\(item.isVisible) length=\(item.length) windowFrame=\(frameDesc) visible=\(win?.isVisible ?? false) occluded=\(occluded)")
        if !item.isVisible || win == nil || win?.isVisible != true {
            DiagnosticLog.debug("statusIcon: unhealthy — recreating")
            hideStatusBarIcon()
            showStatusBarIcon()
            if statusIconHealthTimer == nil {
                scheduleStatusIconHealthChecks()
            }
        }
    }

    /// 启动/重新显示图标后做一小段健康检查。ControlCenter 托管的状态栏项有时延迟分配槽位；
    /// 多次检查只针对「item/window 不存在或不可见」这类确定坏态重建，不使用 parked frame/occlusion
    /// 作为重建条件，避免把健康图标误删重建。
    private func scheduleStatusIconHealthChecks() {
        statusIconHealthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var attempts = 0
        timer.schedule(deadline: .now() + 1.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            attempts += 1
            self.healStatusBarIconIfNeeded()
            if attempts >= 5 {
                self.statusIconHealthTimer?.cancel()
                self.statusIconHealthTimer = nil
            }
        }
        statusIconHealthTimer = timer
        timer.resume()
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
            statusIconHealthTimer?.cancel()
            statusIconHealthTimer = nil
            hideStatusBarIcon()
        } else {
            showStatusBarIcon()
            scheduleStatusIconHealthChecks()
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

    /// 菜单栏下拉「自动居中」快速开关：翻转 centerEnabled 总开关并落盘，
    /// 随后通知设置窗口重载本地状态（菜单→设置窗口同步）。
    /// 生效路径：shouldCenter(bundleID:) 守卫 centerEnabled——关掉后自动居中主循环不再居中任何窗口。
    @objc private func toggleAutoCentering() {
        var s = tilingSettingsStore.load()
        s.centerEnabled.toggle()
        if !tilingSettingsStore.save(s) {
            DiagnosticLog.debug("SettingsStore: menu auto-centering toggle was not persisted")
            NSSound.beep()
        }
        NotificationCenter.default.post(name: SettingsWindowNotifications.settingsChangedExternally, object: nil)
    }

    /// 菜单栏下拉「自动平铺」快速开关：翻转 isEnabled 总开关并落盘，
    /// 随后通知设置窗口重载本地状态（菜单→设置窗口同步）。
    /// 生效路径：shouldTile(bundleID:) 守卫 isEnabled——关掉后平铺白名单内的 app 也不再被平铺。
    @objc private func toggleAutoTiling() {
        var s = tilingSettingsStore.load()
        s.isEnabled.toggle()
        if !tilingSettingsStore.save(s) {
            DiagnosticLog.debug("SettingsStore: menu auto-tiling toggle was not persisted")
            NSSound.beep()
        }
        NotificationCenter.default.post(name: SettingsWindowNotifications.settingsChangedExternally, object: nil)
    }

    /// 菜单打开前由 AppKit 调用（NSMenuDelegate）。读最新 store 状态为两个总开关设勾选标记（.on 显示 ✓），
    /// 使菜单项状态与设置窗口改动天然同步（设置窗口→菜单方向无需额外通知）。
    /// 用 menuNeedsChange 而非 validateMenuItem：menu.autoenablesItems=false 时后者不会被调用，
    /// 两个总开关会因此无勾选标记；前者在菜单每次打开时必定触发，与该开关无关。
    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = tilingSettingsStore.load()
        for item in menu.items {
            switch item.action {
            case #selector(toggleAutoCentering):
                item.state = s.centerEnabled ? .on : .off
            case #selector(toggleAutoTiling):
                item.state = s.isEnabled ? .on : .off
            default:
                break
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
        if let item = statusItem {
            item.length = NSStatusItem.variableLength
            item.autosaveName = Self.statusItemAutosaveName
            item.isVisible = true
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.statusItemAutosaveName
        // 防御：若系统曾持久化过「不可见」状态（isVisible=false），显式拉回可见。
        item.isVisible = true
        if
            let iconURL = Bundle.main.url(forResource: "StatusIconTemplate", withExtension: "png"),
            let statusImage = NSImage(contentsOf: iconURL)
        {
            statusImage.isTemplate = true
            statusImage.size = NSSize(width: 20, height: 20)
            item.button?.image = statusImage
            item.button?.imagePosition = .imageOnly
            item.button?.imageScaling = .scaleProportionallyDown
            item.button?.title = ""
        } else if let statusImage = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Plumb") {
            statusImage.isTemplate = true
            statusImage.size = NSSize(width: 20, height: 20)
            item.button?.image = statusImage
            item.button?.imagePosition = .imageOnly
            item.button?.imageScaling = .scaleProportionallyDown
            item.button?.title = ""
        } else {
            // 图标资源缺失时退回文字，保证菜单入口仍可用。
            item.button?.title = "Plumb"
            DiagnosticLog.debug("statusIcon: StatusIconTemplate.png load FAILED — using title fallback")
        }
        item.button?.toolTip = "Plumb"

        let menu = NSMenu()
        menu.autoenablesItems = false

        // 主操作：立即居中
        let centerItem = menu.addItem(withTitle: L10n.centerNow, action: #selector(centerNow), keyEquivalent: "")
        centerItem.target = self
        centerItem.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)

        // 快速开关：自动居中 / 自动平铺（勾选状态由 menuNeedsChange 在菜单打开时从 store 推导，
        // 与设置窗口改动天然同步）。放在主操作之后、设置… 之前，属高频状态控制项。
        let autoCenterItem = menu.addItem(withTitle: L10n.menuAutoCentering, action: #selector(toggleAutoCentering), keyEquivalent: "")
        autoCenterItem.target = self
        autoCenterItem.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)

        let autoTileItem = menu.addItem(withTitle: L10n.menuAutoTiling, action: #selector(toggleAutoTiling), keyEquivalent: "")
        autoTileItem.target = self
        autoTileItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)

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

        // 设为菜单委托：菜单每次打开前触发 menuNeedsChange，刷新两个总开关的勾选标记，
        // 让用户从下拉即可看到当前开/关状态（autoenablesItems=false 下 validateMenuItem 不被调用）。
        menu.delegate = self

        // 取证日志：下一 runloop 记录图标的状态栏窗口 frame。菜单栏空间不足（图标过多/刘海屏）
        // 时 AppKit 不报错、只是不显示——windowFrame 缺失或落在屏幕外即为「被挤掉」的证据，
        // 与「托管场景不渲染」（frame 正常但用户看不到）可从日志区分。
        DispatchQueue.main.async { [weak item] in
            let win = item?.button?.window
            let frameDesc = win.map { "\($0.frame)" } ?? "nil"
            let screenW = NSScreen.main.map { "\($0.frame.width)" } ?? "?"
            DiagnosticLog.debug("statusIcon: created windowFrame=\(frameDesc) visible=\(win?.isVisible ?? false) mainScreenW=\(screenW)")
        }
    }

    /// 从状态栏移除水滴图标（「隐藏菜单栏图标」开启或切换时调用）。
    private func hideStatusBarIcon() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
