import AppKit

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
