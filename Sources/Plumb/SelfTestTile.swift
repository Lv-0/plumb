import AppKit
import ApplicationServices

/// Self-test harness: creates a fully-controlled NSWindow, then drives the real
/// tiling engine (`WindowCenteringService.tileWindowElement`) against it via AX.
/// Prints the before/after rect so we can authoritatively verify the engine
/// produces a near-fullscreen rect — independent of any external app's quirks.
///
/// Must run under a full app.run() lifecycle so the AX bridge is active.
/// Run: `dist/Plumb.app/Contents/MacOS/Plumb --selftest-tile`

@MainActor
final class SelfTestTileDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    /// MUST be held as an instance property: tileWindowElementAnimated's Phase B completion runs
    /// ~0.3s later via a timer; if the service is a local it gets deallocated before Phase B and
    /// the weak-self capture becomes nil → tiling stalls at Phase A (the bug previously masked).
    private var service: WindowCenteringService?
    private static let logPath = "/tmp/cw_selftest.log"

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
        // fresh log
        try? "".write(toFile: Self.logPath, atomically: true, encoding: .utf8)
        let win = NSWindow(
            contentRect: NSRect(x: 200, y: 600, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "SelfTest Tiling Target"
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.performTile()
        }
    }

    private func performTile() {
        guard window != nil else { finish(); return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        Self.log("SELFTEST: AXIsProcessTrusted() = \(AXIsProcessTrusted()); pid=\(pid)")

        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &ref)
        if ref == nil {
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref)
        }
        guard let r = ref, CFGetTypeID(r) == AXUIElementGetTypeID() else {
            Self.log("SELFTEST: FAIL - could not resolve window AX element")
            finish()
            return
        }
        let windowElement = unsafeDowncast(r, to: AXUIElement.self)

        let before = Self.readFrame(windowElement)
        let visible = NSScreen.screens[0].visibleFrame
        Self.log("SELFTEST: screen visibleFrame=\(visible)")
        Self.log("SELFTEST: window BEFORE tile = \(Self.stringify(before))")

        let service = WindowCenteringService()
        // MUST retain the service for the duration of the animation (Phase B runs ~0.3s later
        // via a timer; without this retention the weak-self capture in runPhaseB becomes nil).
        self.service = service
        // Use the ANIMATED path — this is where commit 0fc9703's AXFrame
        // size-bounce fix lives (completion forces the exact targetFrame).
        do {
            try service.tileWindowElementAnimated(windowElement, pid: pid, appElement: appElement, edgeMargin: 16) { [weak self] in
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let after = Self.readFrame(windowElement)
                    Self.log("SELFTEST: window AFTER animated tile (AX) = \(Self.stringify(after))")
                    if let win = self.window {
                        Self.log("SELFTEST: window AFTER actual NSWindow frame=\(Self.stringify(win.frame)) contentMinSize=\(win.contentMinSize) contentMaxSize=\(win.contentMaxSize) minSize=\(win.minSize) maxSize=\(win.maxSize)")
                    }
                    let target = CGRect(
                        x: visible.minX + 16, y: visible.minY + 16,
                        width: visible.width - 32, height: visible.height - 32
                    )
                    Self.log("SELFTEST: expected near-fullscreen ≈ \(Self.stringify(target))")
                    let tol: CGFloat = 24
                    let nearFullscreen =
                        abs(after.minX - target.minX) <= tol &&
                        abs(after.minY - target.minY) <= tol &&
                        abs(after.width - target.width) <= tol &&
                        abs(after.height - target.height) <= tol
                    let grew = (after.width > before.width + 100) && (after.height > before.height + 100)
                    Self.log("SELFTEST: near-fullscreen? \(nearFullscreen)   grew-from-small? \(grew)")
                    Self.log("SELFTEST: RESULT=\(nearFullscreen && grew ? "PASS" : "CHECK")")
                    self.finish()
                }
            }
            Self.log("SELFTEST: tileWindowElementAnimated started OK (no throw)")
        } catch {
            Self.log("SELFTEST: tileWindowElementAnimated threw: \(error)")
            finish()
        }
    }

    private func finish() {
        NSApp.stop(nil)
    }

    private static func readFrame(_ element: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var p = CGPoint.zero
        var s = CGSize.zero
        if let posVal = posRef { AXValueGetValue(posVal as! AXValue, .cgPoint, &p) }
        if let sizeVal = sizeRef { AXValueGetValue(sizeVal as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    private static func stringify(_ r: CGRect) -> String {
        "x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))"
    }
}
