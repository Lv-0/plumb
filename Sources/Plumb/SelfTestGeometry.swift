import AppKit
import ApplicationServices

/// No-AX geometry verification: applies the pure `WindowGeometry.tiledFrame` rect
/// to a controlled NSWindow via direct setFrame (no Accessibility needed), then
/// reads back the on-screen frame to PROVE the near-fullscreen rect renders.
///
/// This isolates the geometry (requirement 3's core) from the AX-write concern
/// (which needs a trusted GUI session this environment lacks).
///
/// Trigger: `defaults write com.comet.plumb selftestGeo -bool true` then `open`.

@MainActor
final class SelfTestGeometryDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private static let logPath = "/tmp/cw_selftest_geo.log"

    private static func log(_ message: String) {
        print(message)
        let line = message + "\n"
        if let data = line.data(using: .utf8) {
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

        let visible = NSScreen.screens[0].visibleFrame
        let win = NSWindow(
            contentRect: NSRect(x: 200, y: 600, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Geo SelfTest"
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.performGeometryCheck(visible: visible)
        }
    }

    private func performGeometryCheck(visible: CGRect) {
        guard let window else { finish(); return }

        // The EXACT computation the engine uses (pure, no AX).
        let target = WindowGeometry.tiledFrame(visibleFrame: visible, edgeMargin: 16)
        Self.log("GEO: screen visibleFrame=\(visible)")
        Self.log("GEO: tiledFrame target = \(Self.stringify(target))")

        // BEFORE
        let before = window.frame
        Self.log("GEO: window BEFORE = \(Self.stringify(before))")

        // Apply the target rect DIRECTLY (no AX, just NSWindow.setFrame).
        window.setFrame(target, display: true)

        // Pump runloop so the window server commits the frame.
        for _ in 0..<20 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03)) }

        // AFTER — read back the ACTUAL on-screen frame.
        let after = window.frame
        Self.log("GEO: window AFTER  = \(Self.stringify(after))")

        // Verdict: does the window now occupy the near-fullscreen rect?
        let tol: CGFloat = 2
        let match =
            abs(after.minX - target.minX) <= tol &&
            abs(after.minY - target.minY) <= tol &&
            abs(after.width - target.width) <= tol &&
            abs(after.height - target.height) <= tol
        let grew = (after.width > before.width + 100) && (after.height > before.height + 100)
        let nearFullscreenCoverage = (after.width * after.height) / (visible.width * visible.height)

        Self.log("GEO: target-applied exactly? \(match)")
        Self.log("GEO: grew from small? \(grew)")
        Self.log("GEO: visibleFrame coverage = \(String(format: "%.1f%%", nearFullscreenCoverage * 100))")
        Self.log("GEO: RESULT=\(match && grew ? "PASS" : "CHECK")")
        // Keep window on screen long enough to screenshot, then exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in self?.finish() }
    }

    private func finish() {
        NSApp.stop(nil)
    }

    private static func stringify(_ r: CGRect) -> String {
        "x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))"
    }
}
