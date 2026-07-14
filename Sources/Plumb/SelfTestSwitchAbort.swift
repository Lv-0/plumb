import AppKit
import ApplicationServices

/// App-switch centering self-test (需求: "平铺 Safari → 切换 Music → Music 不居中").
///
/// Reproduces the false "user moved window" abort that used to kill auto-centering right after
/// an app is activated. The WindowAnimator reader compared the read-back position against the
/// last-written frame; during app activation macOS itself bounces/animates the window, producing
/// a spurious single-frame >40px delta → the centering animation aborted immediately and the
/// window never reached center.
///
/// This harness drives the REAL engine against a REAL app window, and CRUCIALLY deactivates then
/// re-activates the target app before each centering run — exercising the macOS activation bounce
/// that triggered the bug. Each run: switch AWAY to another app, switch BACK to target (activation
/// animation fires), then immediately center via the real engine, and check the window actually
/// reached center (did not abort).
///
/// Trigger: `defaults write com.comet.plumb selftestSwitchAbort -bool true`
/// then run `dist/Plumb.app/Contents/MacOS/Plumb`.
/// Requires TextEdit running with one document + at least one OTHER app to switch away to
/// (Finder is used as the "away" app). Output: /tmp/cw_selftest_switch_abort.log

@MainActor
final class SelfTestSwitchAbortDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_switch_abort.log"
    private var service: WindowCenteringService!
    private var target: NSRunningApplication!   // TextEdit — gets centered each round.
    private var away: NSRunningApplication!      // Finder — switched to between rounds.
    private var window: AXUIElement!
    private var attempts = 0
    private let maxAttempts = 10
    private var reached = 0
    private var failed = 0

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
        let targetID = "com.apple.TextEdit"
        let awayID = "com.apple.finder"
        guard let t = NSRunningApplication.runningApplications(withBundleIdentifier: targetID).first else {
            Self.log("ABORT-TEST: FAIL — \(targetID) not running"); finish(); return
        }
        // Finder is essentially always running; if not, fall back to Safari/Mail/etc.
        let a = NSRunningApplication.runningApplications(withBundleIdentifier: awayID).first
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first
        guard let a else {
            Self.log("ABORT-TEST: FAIL — no 'away' app (Finder/Safari/Mail) running"); finish(); return
        }
        target = t
        away = a
        service = WindowCenteringService()
        Self.log("ABORT-TEST: target pid=\(t.processIdentifier) away=\(a.bundleIdentifier ?? "?") attempts=\(maxAttempts)")
        testNext()
    }

    private func testNext() {
        guard attempts < maxAttempts else {
            Self.log("ABORT-TEST: SUMMARY attempts=\(attempts) reachedCenter=\(reached) aborted/failed=\(failed)")
            let pass = failed == 0
            Self.log("ABORT-TEST: RESULT=\(pass ? "PASS" : "FAIL (\(failed) runs did NOT reach center — false abort)")")
            finish(); return
        }
        attempts += 1

        // 1) Switch AWAY to the other app (deactivate target).
        away.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            // 2) Place target window OFF-center while it's in background.
            self.locateAndPlaceOffCenter { ok in
                guard ok else {
                    Self.log("ABORT-TEST: attempt \(self.attempts) — no window, skip")
                    self.failed += 1
                    self.testNext(); return
                }
                // 3) Switch BACK to target — macOS fires activation animation here.
                self.target.activate(options: [])
                // 4) Center via the real engine right as activation completes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.centerAndCheck()
                }
            }
        }
    }

    private func locateAndPlaceOffCenter(_ completion: @escaping (Bool) -> Void) {
        let appEl = AXUIElementCreateApplication(target.processIdentifier)
        var wr: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &wr)
        guard let w = (wr as? [AXUIElement])?.first else { completion(false); return }
        window = w
        let vf = (NSScreen.main ?? NSScreen.screens.first!).visibleFrame
        var sz = CGSize(width: 760, height: 520)
        if let v = AXValueCreate(.cgSize, &sz) { _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
        // Off-center: bottom-left of visibleFrame.
        var pos = CGPoint(x: vf.minX + 30, y: vf.minY + 30)
        if let v = AXValueCreate(.cgPoint, &pos) { _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
        completion(true)
    }

    private func centerAndCheck() {
        let before = readFrame()
        let vf = (NSScreen.main ?? NSScreen.screens.first!).visibleFrame
        let beforeDist = distanceFromCenter(before, screenCenter: vf)
        do {
            try service.centerWindowElementAnimated(window, pid: target.processIdentifier, appElement: AXUIElementCreateApplication(target.processIdentifier)) { [weak self] outcome in
                guard let self else { return }
                guard outcome == .finished else {
                    self.failed += 1
                    Self.log("ABORT-TEST: attempt \(self.attempts) ended with \(outcome)")
                    self.testNext()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let after = self.readFrame()
                    let afterDist = self.distanceFromCenter(after, screenCenter: vf)
                    // Window "reached center" if it moved substantially closer to screen center.
                    let reachedCenter = afterDist < beforeDist * 0.5
                    if reachedCenter {
                        self.reached += 1
                        Self.log("ABORT-TEST: attempt \(self.attempts) beforeDist=\(Int(beforeDist)) afterDist=\(Int(afterDist)) reachedCenter=YES pos=(\(Int(after.minX)),\(Int(after.minY)))")
                    } else {
                        self.failed += 1
                        Self.log("ABORT-TEST: attempt \(self.attempts) beforeDist=\(Int(beforeDist)) afterDist=\(Int(afterDist)) reachedCenter=NO pos=(\(Int(after.minX)),\(Int(after.minY))) (likely aborted)")
                    }
                    self.testNext()
                }
            }
        } catch {
            Self.log("ABORT-TEST: attempt \(attempts) threw \(error)")
            failed += 1
            testNext()
        }
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

    private func distanceFromCenter(_ r: CGRect, screenCenter: CGRect) -> CGFloat {
        let cx = screenCenter.midX
        let cy = screenCenter.midY
        let dx = r.midX - cx
        let dy = r.midY - cy
        return (dx*dx + dy*dy).squareRoot()
    }

    private func finish() {
        Self.log("ABORT-TEST: DONE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
}
