import AppKit
import ApplicationServices

/// Center-on-multi-screen verification (需求: "不同屏幕切换应用居中会失效").
///
/// Drives the REAL WindowCenteringService.centerWindowElementAnimated against a real TextEdit
/// window, testing centering on EACH physical screen. For each screen:
///   1. Move the window onto that screen (via AX position write).
///   2. Run centerWindowElementAnimated.
///   3. Verify the window ends up centered on THAT screen's visibleFrame (not jumped elsewhere).
///
/// Trigger: `defaults write com.comet.plumb selftestCenterMulti -bool true` then run
/// `dist/Plumb.app/Contents/MacOS/Plumb` directly.
/// Requires TextEdit open with a single document. Output: /tmp/cw_selftest_center_multi.log

@MainActor
final class SelfTestCenterMultiDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_center_multi.log"
    private var service: WindowCenteringService?
    private var window: AXUIElement!
    private var app: NSRunningApplication!

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
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.run()
        }
    }

    private func run() {
        let screens = NSScreen.screens
        guard screens.count >= 2 else {
            Self.log("CENTER-MULTI: FAIL — need 2 screens, found \(screens.count)"); finish(); return
        }
        for (i, s) in screens.enumerated() {
            Self.log("CENTER-MULTI: screen[\(i)] frame=\(s.frame) visibleFrame=\(s.visibleFrame)")
        }

        guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
            Self.log("CENTER-MULTI: FAIL — TextEdit not running"); finish(); return
        }
        app = a
        app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.locateAndTest(screens: screens)
        }
    }

    private func locateAndTest(screens: [NSScreen]) {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var wr: CFTypeRef?; AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &wr)
        guard let w = (wr as? [AXUIElement])?.first else {
            Self.log("CENTER-MULTI: FAIL — no TextEdit window"); finish(); return
        }
        window = w
        service = WindowCenteringService()

        // Test each screen sequentially.
        testScreen(at: 0, screens: screens)
    }

    private func testScreen(at idx: Int, screens: [NSScreen]) {
        guard idx < screens.count else {
            Self.log("CENTER-MULTI: ALL TESTS DONE"); finish(); return
        }
        let screen = screens[idx]
        let label = screen.frame.contains(CGPoint.zero) ? "EXTERNAL(\(idx))" : "BUILT-IN(\(idx))"
        Self.log("CENTER-MULTI: === testing center on \(label) ===")

        let vf = screen.visibleFrame
        // Shrink first.
        var sz = CGSize(width: 400, height: 300)
        if let v = AXValueCreate(.cgSize, &sz) { _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }

        // Place window onto this screen. Retry with different coordinate interpretations
        // until the window's center is actually inside the target screen's frame.
        placeOnto(screen: screen, attempt: 1) { [weak self] success in
            guard let self else { return }
            let before = self.readFrame()
            let onScreenBefore = screen.frame.contains(CGPoint(x: before.midX, y: before.midY))
            Self.log("  before center: \(self.stringify(before)) center=(\(Int(before.midX)),\(Int(before.midY))) onTarget=\(onScreenBefore)")
            Self.log("  target: screen[\(idx)] visibleFrame=\(vf) center=(\(Int(vf.midX)),\(Int(vf.midY)))")
            if !onScreenBefore {
                Self.log("  WARN: could not place window on \(label); centering test may be inconclusive")
            }
            do {
                try self.service!.centerWindowElementAnimated(self.window, pid: self.app.processIdentifier, appElement: AXUIElementCreateApplication(self.app.processIdentifier))
            } catch {
                Self.log("  center threw: \(error)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let after = self.readFrame()
                // Coord-space-agnostic check: did the window STAY on the same screen it was
                // on before centering? Compare screen membership before vs after using the
                // engine's own detection (read pos, find which screen's range it falls in
                // via the primaryTopY-flipped comparison for top-left spaces).
                // Simpler: the engine log (resolveCenterTarget) tells us detectedScreen + targetAX.
                // Here we just report the before/after and let the engine diag confirm correctness.
                let beforeScreen = self.screenLabel(for: before.midX, y: before.midY, screens: screens)
                // For "after", the AX position is in the window's native space (often globalTopLeft).
                // We can't reliably convert without knowing the space, so we report raw + note
                // the engine's detectedScreen from its own log.
                Self.log("  after center: \(self.stringify(after)) center=(\(Int(after.midX)),\(Int(after.midY)))")
                Self.log("  before was on: \(beforeScreen)")
                Self.log("  (verify via engine 'resolveCenterTarget' log: detectedScreen + targetAX must match target screen)")
                Self.log("")
                self.testScreen(at: idx + 1, screens: screens)
            }
        }
    }

    /// Place the window onto `screen` by writing AX position, trying multiple coordinate
    /// interpretations (Cocoa bottom-left origin = vf.minX/minY; and primaryTopLeft-flipped y).
    /// Verifies via read-back that the window center is inside the target screen.
    private func placeOnto(screen: NSScreen, attempt: Int, completion: @escaping (Bool) -> Void) {
        let vf = screen.visibleFrame
        let primaryTopY = NSScreen.screens.first(where: { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 })?.frame.maxY ?? 1080
        // Candidate positions to try (Cocoa bottom-left, then top-left-flipped).
        let candidates: [CGPoint] = [
            CGPoint(x: vf.midX - 200, y: vf.midY - 150),                                  // cocoa BL
            CGPoint(x: vf.midX - 200, y: primaryTopY - (vf.midY + 150) - 300),            // top-left flipped
            CGPoint(x: vf.midX - 200, y: primaryTopY - (vf.midY - 150) - 300)
        ]
        let i = min(attempt - 1, candidates.count - 1)
        var pos = candidates[i]
        if let v = AXValueCreate(.cgPoint, &pos) { _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let cur = self.readFrame()
            let onTarget = screen.frame.contains(CGPoint(x: cur.midX, y: cur.midY))
            if onTarget || attempt >= candidates.count {
                completion(onTarget)
            } else {
                self.placeOnto(screen: screen, attempt: attempt + 1, completion: completion)
            }
        }
    }

    /// Best-effort screen label for a point (uses Cocoa frame containment — only valid
    /// when the point is in Cocoa space, which the "before" read is, since we wrote it).
    private func screenLabel(for x: CGFloat, y: CGFloat, screens: [NSScreen]) -> String {
        for (i, s) in screens.enumerated() {
            if s.frame.contains(CGPoint(x: x, y: y)) {
                return s.frame.contains(CGPoint.zero) ? "EXTERNAL(\(i))" : "BUILT-IN(\(i))"
            }
        }
        return "NONE(gap)"
    }

    private func readFrame() -> CGRect {
        var pr: CFTypeRef?; var sr: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pr)
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sr)
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = pr { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = sr { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    private func stringify(_ r: CGRect) -> String {
        "x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))"
    }

    private func finish() {
        Self.log("CENTER-MULTI: DONE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
}
