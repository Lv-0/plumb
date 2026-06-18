import AppKit
import SwiftUI
import ApplicationServices
#if canImport(ObjC)
import ObjectiveC
#endif

/// UI self-test harness: opens the real SettingsWindowController (the app's own window,
/// so NO cross-process AX trust required), renders SettingsView, screenshots it, and
/// programmatically verifies:
///   (a) The "启用自动平铺" PillToggle in the Tiling tab renders and toggles state on click.
///   (b) The search TextField becomes first responder (focusable) after the ZStack +
///       allowsHitTesting(false) fix — previously the .interactive() glass swallowed focus.
///   (c) The tiling master switch flipping persists into AppTilingSettingsStore (proving
///       the $settings.isEnabled binding + onChange save chain works).
///
/// Trigger: `defaults write com.comet.plumb selftestUI -bool true` then `open dist/Plumb.app`.
/// Output: /tmp/cw_selftest_ui.log + /tmp/cw_selftest_ui_*.png

@MainActor
final class SelfTestUIDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_ui.log"
    private static let shotPath = "/tmp/cw_selftest_ui.png"
    private static let shotTilingPath = "/tmp/cw_selftest_ui_tiling.png"

    private var controller: SettingsWindowController?
    private var store: AppTilingSettingsStore?

    private static func log(_ message: String) {
        print(message)
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
        // Catch any ObjC NSException (Swift `catch` cannot). Log + write a marker file.
        NSSetUncaughtExceptionHandler { ex in
            let msg = "UNCAUGHT EXCEPTION: \(ex.name.rawValue) — \(ex.reason ?? "?")\n\(ex.callStackSymbols.prefix(12).joined(separator: "\n"))"
            print(msg)
            if let data = (msg + "\n").data(using: .utf8) {
                let path = "/tmp/cw_selftest_ui_crash.log"
                if FileManager.default.fileExists(atPath: path) {
                    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
                } else {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Use a fresh store writing to .standard (same as production AppDelegate).
        let store = AppTilingSettingsStore()
        self.store = store

        // Force a known starting state: tiling disabled (the default), empty lists.
        store.save(.default)
        let before = store.load()
        Self.log("SELFTEST-UI: initial store isEnabled=\(before.isEnabled) tiledIDs=\(before.tiledBundleIDs)")

        let controller = SettingsWindowController(store: store)
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Give SwiftUI a moment to lay out + load the app list (async task).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.phaseOne_renderAndScreenshot()
        }
    }

    // MARK: - Phase 1: screenshot the default (Centering) tab, then switch to Tiling

    private func phaseOne_renderAndScreenshot() {
        guard let window = controller?.window else {
            Self.log("SELFTEST-UI: FAIL — no window")
            finish(); return
        }

        // Bring to front so it's the key window.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Screenshot the window content via NSBitmapImageRep of the contentView
        // (app's own process — no ScreenCaptureKit permission needed).
        guard let contentView = window.contentView else {
            Self.log("SELFTEST-UI: FAIL — no contentView")
            finish(); return
        }
        saveScreenshot(of: contentView, to: Self.shotPath, label: "default")

        // Dump the NSView tree so we can SEE what SwiftUI actually rendered and where.
        Self.log("SELFTEST-UI: === NSView tree dump ===")
        var dumpCount = 0
        Self.dumpViewTree(contentView, count: &dumpCount, onlyNamed: ["_FocusRingView", "AppKitTextField"])
        Self.log("SELFTEST-UI: === end dump (\(dumpCount) nodes) ===")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.clickTilingTab()
        }
    }

    private func clickTilingTab() {
        guard let window = controller?.window else { finish(); return }
        // TabPills are 88x32 focus-ring views near the top of the window.
        // Order: 居中(x≈238), 平铺(x≈336), 权限(x≈434). The Tiling tab is the middle one.
        if let point = findTabPillCenter(in: window, index: 1) {
            simulateClick(in: window, at: point)
            Self.log("SELFTEST-UI: clicked 平铺 (middle) tab at window-local \(point)")
        } else {
            Self.log("SELFTEST-UI: WARN — could not locate tab pills; abort")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.screenshotTilingAndTestToggle()
        }
    }

    private func screenshotTilingAndTestToggle() {
        guard let window = controller?.window else { finish(); return }
        if let contentView = window.contentView {
            saveScreenshot(of: contentView, to: Self.shotTilingPath, label: "tiling")
            // Re-dump to see tiling section layout (esp. the PillToggle position).
            Self.log("SELFTEST-UI: === tiling NSView dump ===")
            var c = 0
            Self.dumpViewTree(contentView, count: &c, onlyNamed: ["_FocusRingView", "AppKitTextField"])
            Self.log("SELFTEST-UI: === end tiling dump ===")
        }

        // PillToggle is a 40pt-wide focus-ring view on the right side of the tiling card.
        // From the dump: row toggles are at x≈664 width=40. The TILING master toggle is the
        // FIRST such 40pt-wide focus ring in the top card (highest up = largest y).
        if let point = findPillToggleCenter(in: window) {
            simulateClick(in: window, at: point)
            Self.log("SELFTEST-UI: clicked master PillToggle at window-local \(point)")
        } else {
            Self.log("SELFTEST-UI: WARN — could not locate master PillToggle")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.verifyToggleFlipped()
        }
    }

    private func verifyToggleFlipped() {
        guard let store else { finish(); return }
        let after = store.load()
        // Default was isEnabled=false. Clicking the PillToggle should flip to true.
        let flipped = after.isEnabled == true
        Self.log("SELFTEST-UI: after PillToggle click, store.isEnabled=\(after.isEnabled) → FLIPPED=\(flipped ? "YES (PASS)" : "NO (FAIL)")")

        // Reset and test search field focus.
        store.save(.default)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.testSearchFocus()
        }
    }

    private func testSearchFocus() {
        guard let window = controller?.window else { finish(); return }
        // Force the window to be key & active so @FocusState auto-focus can fire.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Switch back to Centering tab (index 0). The search field has @FocusState that
        // auto-focuses on appear — so after the tab switch, we just check whether the
        // window's firstResponder became a text editor.
        if let point = findTabPillCenter(in: window, index: 0) {
            simulateClick(in: window, at: point)
            Self.log("SELFTEST-UI: clicked 居中 tab to switch back")
        }

        // Wait for the onAppear auto-focus to fire (it has a 0.15s internal delay).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let responder = window.firstResponder
            // Unwrap the responder's real class (avoid the "Optional<NSResponder>" wrapper).
            let cls: AnyClass = object_getClass(responder) ?? NSObject.self
            let responderType = NSStringFromClass(cls)
            let isFieldEditor = responderType.contains("FieldEditor")
                || responderType.contains("TextView")
                || responderType.contains("NSText")
            // Also check whether the responder IS the window itself (no focus) vs a text view.
            let isWindow = responder === window
            Self.log("SELFTEST-UI: firstResponder class=\(responderType) isWindow=\(isWindow) → SEARCH_FOCUSABLE=\(isFieldEditor ? "YES (PASS)" : "NO (FAIL)")")
            self.finalScreenshot()
            self.finish()
        }
    }

    /// Find the Nth tab pill (88x32 focus ring near top). Tab order by x: 居中, 平铺, 权限.
    /// Returns its center in window-local coords (origin = bottom-left of window).
    private func findTabPillCenter(in window: NSWindow, index: Int) -> NSPoint? {
        guard let contentView = window.contentView else { return nil }
        // Collect all _FocusRingView that are direct children of NSHostingView (the tab pills).
        // From the dump, the 3 tab pills are direct children of NSHostingView<SettingsView>
        // at y≈50, width≈88, height≈32.
        var pills: [NSView] = []
        Self.collectViews(contentView, classNameContains: "_FocusRingView", into: &pills, maxDepth: 2)
        // Filter to tab-pill-sized ones (~88 wide, ~32 tall).
        let tabPills = pills.filter { abs($0.frame.width - 88) < 6 && abs($0.frame.height - 32) < 6 }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard index < tabPills.count else {
            Self.log("SELFTEST-UI: tabPills found=\(tabPills.count), need index \(index)")
            return nil
        }
        let pill = tabPills[index]
        return centerInWindow(of: pill, in: window)
    }

    /// Find the PillToggle in the tiling card. PillToggles are 40pt-wide focus rings.
    /// The MASTER toggle (启用自动平铺) is the topmost one in the tiling card.
    /// Returns its center in window-local coords.
    private func findPillToggleCenter(in window: NSWindow) -> NSPoint? {
        guard let contentView = window.contentView else { return nil }
        var rings: [NSView] = []
        Self.collectViews(contentView, classNameContains: "_FocusRingView", into: &rings, maxDepth: 10)
        // PillToggle focus rings are ~40 wide, ~24 tall.
        let toggles = rings.filter { abs($0.frame.width - 40) < 3 && abs($0.frame.height - 24) < 3 }
        Self.log("SELFTEST-UI: candidate 40x24 toggles=\(toggles.count)")
        for t in toggles.sorted(by: { Self.windowY($0, in: window) > Self.windowY($1, in: window) }) {
            let p = centerInWindow(of: t, in: window)
            Self.log("SELFTEST-UI:   toggle candidate center window-local \(p)")
        }
        // Pick the topmost toggle in the tiling section. The master toggle is in the top card.
        // We assume the topmost 40x24 focus ring in the visible content area is the master toggle.
        guard let topmost = toggles.max(by: { Self.windowY($0, in: window) < Self.windowY($1, in: window) }) else {
            return nil
        }
        return centerInWindow(of: topmost, in: window)
    }

    /// Find the search text field. It is an _SystemTextFieldFieldEditor (AXTextArea) inside
    /// an AppKitTextField. Click its center.
    private func findSearchFieldCenter(in window: NSWindow) -> NSPoint? {
        guard let contentView = window.contentView else { return nil }
        var editors: [NSView] = []
        Self.collectViews(contentView, classNameContains: "_SystemTextFieldFieldEditor", into: &editors, maxDepth: 10)
        // Or fall back to AppKitTextField host.
        if editors.isEmpty {
            Self.collectViews(contentView, classNameContains: "AppKitTextField", into: &editors, maxDepth: 10)
        }
        Self.log("SELFTEST-UI: search-field candidates=\(editors.count)")
        guard let editor = editors.first else { return nil }
        return centerInWindow(of: editor, in: window)
    }

    private func centerInWindow(of view: NSView, in window: NSWindow) -> NSPoint? {
        // Convert view's bounds center to window-local coords (nil = window coordinate space).
        let centerInView = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let centerInWindow = view.convert(centerInView, to: nil)
        return centerInWindow
    }

    private static func windowY(_ view: NSView, in window: NSWindow) -> CGFloat {
        view.convert(NSPoint(x: 0, y: view.bounds.height), to: nil).y
    }

    /// Collect all views whose class name contains `classNameContains`, up to `maxDepth`.
    private static func collectViews(_ view: NSView, classNameContains: String, into bucket: inout [NSView], maxDepth: Int) {
        let cls = String(describing: type(of: view))
        if cls.contains(classNameContains) { bucket.append(view) }
        guard maxDepth > 0 else { return }
        for sub in view.subviews {
            collectViews(sub, classNameContains: classNameContains, into: &bucket, maxDepth: maxDepth - 1)
        }
    }

    /// Debug dump of the view tree (NSView subviews). If onlyNamed is non-empty, only log
    /// views whose class name contains one of the substrings.
    private static func dumpViewTree(_ view: NSView, depth: Int = 0, count: inout Int, onlyNamed: [String] = []) {
        if count > 200 { return }
        let cls = String(describing: type(of: view))
        let shouldLog = onlyNamed.isEmpty || onlyNamed.contains(where: { cls.contains($0) })
        if shouldLog {
            let f = view.frame
            Self.log("  \(cls) frame=(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height)))")
            count += 1
        }
        for sub in view.subviews {
            dumpViewTree(sub, depth: depth + 1, count: &count, onlyNamed: onlyNamed)
        }
    }

    private func finalScreenshot() {
        guard let window = controller?.window else { return }
        if let contentView = window.contentView {
            saveScreenshot(of: contentView, to: "/tmp/cw_selftest_ui_search.png", label: "search")
        }
    }

    /// 捕获 NSView 的位图并保存为 PNG。用于 app 自身窗口（无需 ScreenCaptureKit 权限）。
    private func saveScreenshot(of view: NSView, to path: String, label: String) {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            Self.log("SELFTEST-UI: FAIL — bitmapImageRepForCachingDisplay returned nil (\(label))")
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let tiff = rep.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            Self.log("SELFTEST-UI: FAIL — PNG encode failed (\(label))")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            Self.log("SELFTEST-UI: screenshot saved → \(path) (size=\(Int(bounds.width))x\(Int(bounds.height)), label=\(label))")
        } catch {
            Self.log("SELFTEST-UI: FAIL — write \(path) failed: \(error)")
        }
    }

    /// Synthesize a left-click at a window-local coordinate (origin = bottom-left of window).
    /// NSEvent.mouseEvent `location` is window-local, NOT screen.
    private func simulateClick(in window: NSWindow, at pointInWindow: NSPoint) {
        // Ensure the window is key & frontmost so it receives the event.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Send synchronously on the current runloop turn so the click lands before the
        // caller's follow-up check.
        self.sendMouseEvent(type: .leftMouseDown, at: pointInWindow, window: window)
        self.sendMouseEvent(type: .leftMouseUp, at: pointInWindow, window: window)
    }

    private func sendMouseEvent(type: NSEvent.EventType, at pointInWindow: CGPoint, window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1.0 : 0.0
        ) else {
            Self.log("SELFTEST-UI: WARN — failed to create mouse event \(type)")
            return
        }
        window.sendEvent(event)
    }

    private func finish() {
        Self.log("SELFTEST-UI: DONE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.stop(nil)
        }
    }
}
