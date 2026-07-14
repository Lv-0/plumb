import AppKit
import ApplicationServices

/// Secondary-window suppression self-test (需求 3: "软件本体居中就行，打开的二级标签
/// 或页面不要进行居中").
///
/// Drives the REAL WindowEventObserver + WindowCenteringService pipeline against a real app
/// (TextEdit), then triggers a secondary window (the Open dialog) via AX menu press, and
/// verifies the secondary window is NOT moved/centered — proving processedPIDs suppression
/// works through the genuine AX-event flow.
///
/// Sequence:
///   1. Activate TextEdit (in tiling list), instantiate observer + service.
///   2. attachToFrontmostApp → observer tiles the main window → processedPIDs[pid] = true.
///   3. Record main window frame after tiling.
///   4. Via AX, press File → Open… menu item → an Open dialog (secondary window) appears.
///   5. Record the Open dialog's initial frame, wait for any centering attempts.
///   6. Verify the Open dialog frame did NOT change (processedPIDs suppressed it).
///
/// Trigger: `defaults write com.comet.plumb selftestSecondary -bool true` then run
/// `dist/Plumb.app/Contents/MacOS/Plumb` directly.
/// Output: /tmp/cw_selftest_secondary.log

@MainActor
final class SelfTestSecondaryWindowDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_secondary.log"
    private var service: WindowCenteringService?
    private var observer: WindowEventObserver?
    private var store: AppTilingSettingsStore?
    private var testedApp: NSRunningApplication?
    private var secondaryWindow: AXUIElement?

    private static func log(_ message: String) {
        print(message)
        SelfTestOutcome.observe(message)
        if let data = (message + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let h = FileHandle(forWritingAtPath: logPath) {
                    h.seekToEndOfFile(); h.write(data); h.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? "".write(toFile: Self.logPath, atomically: true, encoding: .utf8)
        // Use ACCESSORY so our harness does NOT steal frontmost from TextEdit — the observer's
        // handle() requires frontmostApp == pid, so TextEdit must stay frontmost throughout.
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.run()
        }
    }

    private func run() {
        let bundleID = "com.apple.TextEdit"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            Self.log("SELFTEST-SEC: FAIL — \(bundleID) not running. Open it + create a doc first.")
            finish(); return
        }
        testedApp = app
        app.activate(options: [.activateAllWindows])
        // Close any extra windows via AX so we start with exactly 1 main window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.closeExtraMainWindowsThenProceed(app: app)
        }
    }

    private func closeExtraMainWindowsThenProceed(app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef)
        let wins = (winsRef as? [AXUIElement]) ?? []
        let mains = wins.filter { readSubrole($0) == kAXStandardWindowSubrole as String }
        Self.log("SELFTEST-SEC: found \(mains.count) main windows; closing extras")
        // Close all but the first main window via AX (button or Cmd+W).
        for extra in mains.dropFirst() {
            // Try AXClose button first.
            var btnRef: CFTypeRef?
            AXUIElementCopyAttributeValue(extra, kAXCloseButtonAttribute as CFString, &btnRef)
            if let btn = btnRef, CFGetTypeID(btn) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(unsafeDowncast(btn, to: AXUIElement.self), kAXPressAction as CFString)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.setupObserverAndTile(app: app)
        }
    }

    private func setupObserverAndTile(app: NSRunningApplication) {
        // Verify exactly ONE main window exists before starting (clean state).
        // AXWindows can be empty right after activation; poll briefly.
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        var attempt = 0
        func pollForMain() {
            attempt += 1
            var winsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef)
            var wins = (winsRef as? [AXUIElement]) ?? []
            // Fallback: system-wide focused window (same as observer's fallback).
            if wins.isEmpty {
                let sys = AXUIElementCreateSystemWide()
                var fRef: CFTypeRef?
                AXUIElementCopyAttributeValue(sys, kAXFocusedWindowAttribute as CFString, &fRef)
                if let fVal = fRef, CFGetTypeID(fVal) == AXUIElementGetTypeID() {
                    let fw = unsafeDowncast(fVal, to: AXUIElement.self)
                    var ownerPID: pid_t = 0
                    AXUIElementGetPid(fw, &ownerPID)
                    if ownerPID == pid { wins = [fw] }
                }
            }
            let mainWins = wins.filter { readSubrole($0) == kAXStandardWindowSubrole as String }
            Self.log("SELFTEST-SEC: poll#\(attempt) windows=\(wins.count) mainWins=\(mainWins.count)")
            if mainWins.count == 1 {
                self.proceedWithMain(app: app, appEl: appEl, mainWindow: mainWins[0])
            } else if attempt < 6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pollForMain() }
            } else {
                Self.log("SELFTEST-SEC: FAIL — could not get exactly 1 main window after \(attempt) polls (got \(mainWins.count)).")
                self.finish()
            }
        }
        pollForMain()
    }

    private func proceedWithMain(app: NSRunningApplication, appEl: AXUIElement, mainWindow: AXUIElement) {
        let mainBefore = readFrame(mainWindow)
        Self.log("SELFTEST-SEC: main BEFORE = \(stringify(mainBefore))")

        // Configure store: tiling ENABLED + TextEdit in tiling list.
        let store = AppTilingSettingsStore()
        let settings = AppTilingSettings(
            isEnabled: true,
            edgeInsets: TileInsets(all: 16),
            tiledBundleIDs: ["com.apple.textedit"],
            hideSystemAppsInPicker: true,
            centerEnabled: true,
            centeredBundleIDs: [],
            documentChooserBundleIDs: []
        )
        store.save(settings)
        self.store = store

        let service = WindowCenteringService()
        self.service = service
        let observer = WindowEventObserver(service: service, tilingSettingsStore: store)
        self.observer = observer
        observer.start()

        Self.log("SELFTEST-SEC: observer started, tiling enabled for TextEdit (isEnabled=true)")

        // Give the observer time to attach + tile the main window (initial retries ~0.25s).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.recordMainFrameAndOpenDialog(app: app, mainWindow: mainWindow, mainBefore: mainBefore)
        }
    }

    private func recordMainFrameAndOpenDialog(app: NSRunningApplication, mainWindow: AXUIElement, mainBefore: CGRect) {
        let mainAfter = readFrame(mainWindow)
        let mainGrew = (mainAfter.width > mainBefore.width + 100) || (mainAfter.height > mainBefore.height + 100)
        Self.log("SELFTEST-SEC: main AFTER observer = \(stringify(mainAfter)) grew=\(mainGrew)")
        if !mainGrew {
            Self.log("SELFTEST-SEC: FAIL — main window did NOT grow, so secondary suppression was not tested through a working layout pipeline")
        }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        // Trigger a secondary window via File → Open… (AXPress on the menu item).
        // Try multiple localizations first; fall back to Cmd+O keyboard shortcut (locale-independent).
        let menuItem = findMenuItem(appEl, path: ["File", "Open…"])
            ?? findMenuItem(appEl, path: ["File", "Open..."])
            ?? findMenuItem(appEl, path: ["文件", "打开…"])
            ?? findMenuItem(appEl, path: ["文件", "打开..."])
        if let menuItem {
            Self.log("SELFTEST-SEC: pressing File → Open… to trigger secondary window")
            pressMenuItem(menuItem)
        } else {
            Self.log("SELFTEST-SEC: menu item not found (locale); using Cmd+O shortcut")
            sendCmdO()
        }

        // Wait for the Open panel to appear, then record its frame + verify no movement.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.verifySecondaryWindow(app: app, mainWindow: mainWindow)
        }
    }

    private func verifySecondaryWindow(app: NSRunningApplication, mainWindow: AXUIElement) {
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef)
        let wins = (winsRef as? [AXUIElement]) ?? []
        Self.log("SELFTEST-SEC: windows count after Open = \(wins.count)")
        for (i, w) in wins.enumerated() {
            Self.log("  win[\(i)] role=\(readRole(w)) subrole=\(readSubrole(w)) frame=\(stringify(readFrame(w)))")
        }

        // Secondary = any window that is NOT the main window (different AX element).
        // Sheets attach to the main window; standalone dialogs appear as separate AXWindows.
        let secondary = wins.first(where: { w in
            !CFEqual(w, mainWindow) && (isSecondaryWindow(w) || readRole(w) == kAXWindowRole as String)
        })
        guard let secondary else {
            Self.log("SELFTEST-SEC: FAIL — no secondary window found after Open")
            finish(); return
        }
        secondaryWindow = secondary

        let beforeSecondary = readFrame(secondary)
        Self.log("SELFTEST-SEC: secondary frame = \(stringify(beforeSecondary)) subrole=\(readSubrole(secondary))")

        // Wait another interval for any delayed centering/tile to fire.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let afterSecondary = self.readFrame(secondary)
            let moved = abs(afterSecondary.minX - beforeSecondary.minX) > 5 ||
                abs(afterSecondary.minY - beforeSecondary.minY) > 5 ||
                abs(afterSecondary.width - beforeSecondary.width) > 5 ||
                abs(afterSecondary.height - beforeSecondary.height) > 5
            Self.log("SELFTEST-SEC: secondary after wait = \(self.stringify(afterSecondary)) moved=\(moved)")
            Self.log("SELFTEST-SEC: RESULT=\(moved ? "FAIL (secondary moved — suppression broken)" : "PASS (secondary not moved)")")
            self.closeSecondaryWindow()
            self.finish()
        }
    }

    // MARK: - AX helpers

    private func findMenuItem(_ appEl: AXUIElement, path: [String]) -> AXUIElement? {
        var menuBarRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, "AXMenuBar" as CFString, &menuBarRef)
        guard let menuBar = menuBarRef as? [AXUIElement] else { return nil }

        var current: AXUIElement? = menuBar.first(where: { readTitle($0) == path[0] })
        for title in path.dropFirst() {
            guard let parent = current else { return nil }
            var subRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &subRef)
            let children = (subRef as? [AXUIElement]) ?? []
            current = children.first(where: { readTitle($0) == title })
        }
        return current
    }

    private func pressMenuItem(_ item: AXUIElement) {
        AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    /// Send Cmd+O (locale-independent) to the frontmost app to open the Open dialog.
    private func sendCmdO() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let cmd: CGEventFlags = .maskCommand
        // virtualKey 31 = 'O'
        let down = CGEvent(keyboardEventSource: source, virtualKey: 31, keyDown: true)
        down?.flags = cmd
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 31, keyDown: false)
        up?.flags = cmd
        up?.post(tap: .cghidEventTap)
    }

    private func logMenuStructure(_ appEl: AXUIElement) {
        var menuBarRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, "AXMenuBar" as CFString, &menuBarRef)
        guard let menuBar = menuBarRef as? [AXUIElement] else { return }
        for m in menuBar {
            let title = readTitle(m)
            Self.log("  menu: '\(title)'")
            var subRef: CFTypeRef?
            AXUIElementCopyAttributeValue(m, kAXChildrenAttribute as CFString, &subRef)
            if let children = subRef as? [AXUIElement] {
                for c in children.prefix(6) {
                    Self.log("    item: '\(readTitle(c))'")
                }
            }
        }
    }

    private func isSecondaryWindow(_ w: AXUIElement) -> Bool {
        let subrole = readSubrole(w)
        // Secondary = dialog/sheet/utility, NOT a standard main window.
        return subrole == kAXDialogSubrole as String ||
            subrole == kAXSystemDialogSubrole as String ||
            subrole == kAXFloatingWindowSubrole as String ||
            subrole == "AXUnknownSubrole"
    }

    private func closeSecondaryWindow() {
        // Send Escape to dismiss the Open panel.
        guard let app = testedApp else { return }
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Best-effort: press Escape via CGEvent.
            if let source = CGEventSource(stateID: .hidSystemState) {
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: true)
                down?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: false)
                up?.post(tap: .cghidEventTap)
            }
        }
    }

    private func readTitle(_ el: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &r)
        return (r as? String) ?? ""
    }

    private func readRole(_ el: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
        return (r as? String) ?? ""
    }

    private func readSubrole(_ el: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &r)
        return (r as? String) ?? ""
    }

    private func readFrame(_ el: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef)
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = posRef { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = sizeRef { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    private func stringify(_ r: CGRect) -> String {
        "x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))"
    }

    private func finish() {
        Self.log("SELFTEST-SEC: DONE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(SelfTestOutcome.exitCode) }
    }
}
