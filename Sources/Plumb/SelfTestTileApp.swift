import AppKit
import ApplicationServices

/// Real-app tiling self-test: drives the FULL tileWindowElementAnimated path against a
/// REAL third-party app's window (TextEdit by default) — not a bare test NSWindow.
///
/// KEY FINDING (root cause of "tiling doesn't work"): AX size writes (kAXSizeAttribute) are
/// SILENTLY IGNORED when the target app is NOT the frontmost application. The write returns
/// success (.success / 0) but the window does not actually resize. This is why tiling failed:
/// earlier harness runs had the harness process frontmost, not the target app.
///
/// FIX: activate the target app before tiling. This harness verifies that with the app
/// frontmost, the real tiling engine grows the window to near-fullscreen.
///
/// Trigger: `defaults write com.comet.plumb selftestTileApp -bool true` then run
/// `dist/Plumb.app/Contents/MacOS/Plumb` (binary directly for AX trust).
/// Requires TextEdit open with a document. Output: /tmp/cw_selftest_app.log

@MainActor
final class SelfTestTileAppDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_app.log"
    private var service: WindowCenteringService?

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
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.run()
        }
    }

    private func run() {
        let bundleID = "com.apple.TextEdit"   // TextEdit (native).
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            Self.log("SELFTEST-APP: FAIL — \(bundleID) not running. Open it first.")
            finish(); return
        }
        // CRITICAL FIX: AX size writes are silently ignored unless the target app is frontmost.
        // Activate it first, then tile after a short settle delay.
        Self.log("SELFTEST-APP: activating \(bundleID)...")
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.tileActivatedApp(app: app)
        }
    }

    private func tileActivatedApp(app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef)
        guard let wins = winsRef as? [AXUIElement], let window = wins.first else {
            Self.log("SELFTEST-APP: FAIL — no windows for pid=\(pid)")
            finish(); return
        }

        let before = readFrame(window)
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        Self.log("SELFTEST-APP: target pid=\(pid) frontmost=\(isFrontmost)")
        Self.log("SELFTEST-APP: window BEFORE = \(stringify(before))")
        if let screen = NSScreen.main {
            Self.log("SELFTEST-APP: main screen visibleFrame=\(screen.visibleFrame)")
        }

        let service = WindowCenteringService()
        self.service = service
        do {
            try service.tileWindowElementAnimated(window, pid: pid, appElement: appEl, edgeMargin: 16) { [weak self] in
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let after = self.readFrame(window)
                    Self.log("SELFTEST-APP: window AFTER tile = \(self.stringify(after))")
                    let grew = (after.width > before.width + 100) && (after.height > before.height + 100)
                    let nearFullscreen: Bool = {
                        guard let screen = NSScreen.main else { return false }
                        let vf = screen.visibleFrame
                        let tol: CGFloat = 60
                        return abs(after.minX - (vf.minX + 16)) <= tol &&
                            abs(after.width - (vf.width - 32)) <= tol &&
                            abs(after.height - (vf.height - 32)) <= tol
                    }()
                    Self.log("SELFTEST-APP: grew=\(grew) nearFullscreen=\(nearFullscreen)")
                    Self.log("SELFTEST-APP: RESULT=\(grew && nearFullscreen ? "PASS" : "CHECK")")
                    self.finish()
                }
            }
            Self.log("SELFTEST-APP: tileWindowElementAnimated started (no throw)")
        } catch {
            Self.log("SELFTEST-APP: threw: \(error)")
            finish()
        }
    }

    private func finish() {
        Self.log("SELFTEST-APP: DONE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
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
}
