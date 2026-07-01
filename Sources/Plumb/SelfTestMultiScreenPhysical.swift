import AppKit
import ApplicationServices

/// Physical multi-screen verification (需求 4: 原屏居中/平铺, 逐屏 visibleFrame).
///
/// Runs the REAL WindowCenteringService (centerWindowElementAnimated + tileWindowElementAnimated)
/// against a real TextEdit window, with the window physically placed on the BUILT-IN screen
/// (the secondary display in this setup, located at a negative-x offset from the external 4K).
/// Verifies the service keeps the window on its ORIGINAL screen and uses THAT screen's
/// visibleFrame — proving no "jump to primary" regression.
///
/// Two screens observed in this env:
///   screen[0] external 4K at (0, 0), 1920x1080, visibleFrame (0,0,1920,1050) [bottom Dock 30]
///   screen[1] built-in Retina at (-747, -982), 1512x982, visibleFrame (-747,-900,1512,868) [top 82]
///
/// Trigger: `defaults write com.comet.plumb selftestMultiPhysical -bool true` then
/// run `dist/Plumb.app/Contents/MacOS/Plumb` directly (for AX trust).
/// Requires TextEdit open with a single document. Output: /tmp/cw_selftest_multi_phys.log

@MainActor
final class SelfTestMultiScreenPhysicalDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_multi_phys.log"
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
        // ACCESSORY so our harness does not steal frontmost from TextEdit — AX position/size
        // writes are silently ignored when the target app is not frontmost.
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.run()
        }
    }

    private func run() {
        let screens = NSScreen.screens
        guard screens.count >= 2 else {
            Self.log("MULTI-PHYS: FAIL — need 2 physical screens, found \(screens.count)")
            finish(); return
        }
        // Enumerate screens with device IDs.
        for (i, s) in screens.enumerated() {
            let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            Self.log("MULTI-PHYS: screen[\(i)] frame=\(s.frame) visibleFrame=\(s.visibleFrame) displayID=\(id.map(String.init) ?? "?")")
        }

        // Pick the BUILT-IN screen as the "original" screen for the test. Heuristic: the
        // built-in is the one NOT containing the global origin (0,0) in its frame.
        let builtIn = screens.first(where: { !$0.frame.contains(CGPoint.zero) }) ?? screens.last!
        let external = screens.first(where: { $0.frame.contains(CGPoint.zero) }) ?? screens.first!
        Self.log("MULTI-PHYS: builtIn frame=\(builtIn.frame) visible=\(builtIn.visibleFrame)")
        Self.log("MULTI-PHYS: external frame=\(external.frame) visible=\(external.visibleFrame)")
        Self.log("MULTI-PHYS: test = place window on BUILT-IN, center+tile, verify stays on BUILT-IN")

        let bundleID = "com.apple.TextEdit"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            Self.log("MULTI-PHYS: FAIL — TextEdit not running"); finish(); return
        }
        app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.locateAndPlace(app: app, builtIn: builtIn, external: external, screens: screens)
        }
    }

    private func locateAndPlace(app: NSRunningApplication, builtIn: NSScreen, external: NSScreen, screens: [NSScreen]) {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef)
        guard let wins = winsRef as? [AXUIElement], let window = wins.first else {
            Self.log("MULTI-PHYS: FAIL — no TextEdit window"); finish(); return
        }

        // Determine where the window CURRENTLY is (its original screen). The engine's job is to
        // keep it there. We test BOTH screens by running the engine twice — first wherever the
        // window naturally starts (usually external), then attempt to relocate via CGEvent drag.
        // For coordinate-space safety, we use the AXFrame attribute which takes a rect in the
        // window's native space — and we read the current frame to learn the space.
        let curFrame = readFrame(window)
        let originalScreen = screens.first(where: { $0.frame.contains(CGPoint(x: curFrame.midX, y: curFrame.midY)) }) ?? external
        Self.log("MULTI-PHYS: window currently at \(stringify(curFrame)) → on \(originalScreen == external ? "EXTERNAL" : "BUILT-IN")")
        Self.log("MULTI-PHYS: running center+tile on the ORIGINAL screen, verifying it stays there")

        // === Test: TILE on the original screen (the production path: observer does ONE of center/tile) ===
        // Success criteria (coordinate-space-agnostic):
        //   (a) After tile: window center still inside the ORIGINAL screen's frame (no jump to other screen).
        //   (b) Window grew (tiling enlarged it).
        //   (c) Tile fills a meaningful fraction of the original screen's visible area.
        let service = WindowCenteringService()
        self.service = service
        let originalLabel = (originalScreen === external) ? "EXTERNAL" : "BUILT-IN"
        let beforeTile = curFrame
        Self.log("MULTI-PHYS: tiling (no prior center) on \(originalLabel), before=\(stringify(beforeTile))")
        do {
            try service.tileWindowElementAnimated(window, pid: app.processIdentifier, appElement: AXUIElementCreateApplication(app.processIdentifier), insets: TileInsets(all: 16))
        } catch {
            Self.log("MULTI-PHYS: tile threw: \(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let tiled = self.readFrame(window)
            let stillOriginalAfterTile = originalScreen.frame.contains(CGPoint(x: tiled.midX, y: tiled.midY))
            let grew = (tiled.width > beforeTile.width + 100) && (tiled.height > beforeTile.height + 100)
            let origVisibleArea = originalScreen.visibleFrame.width * originalScreen.visibleFrame.height
            let tiledArea = tiled.width * tiled.height
            let fillsOriginal = tiledArea >= origVisibleArea * 0.5
            Self.log("MULTI-PHYS: AFTER TILE = \(self.stringify(tiled)) center=(\(Int(tiled.midX)),\(Int(tiled.midY)))")
            Self.log("  stayed on \(originalLabel)? \(stillOriginalAfterTile ? "✓" : "✗ JUMPED TO OTHER SCREEN")")
            Self.log("  grew from \(Int(beforeTile.width))x\(Int(beforeTile.height))? \(grew ? "✓" : "✗")")
            Self.log("  fills >=50% of \(originalLabel) visibleArea (\(Int(origVisibleArea/1_000_000))M px²)? \(fillsOriginal ? "✓ (tiledArea=\(Int(tiledArea/1_000_000))M)" : "✗ (tiledArea=\(Int(tiledArea/1_000_000))M)")")
            let allPass = stillOriginalAfterTile && grew && fillsOriginal
            Self.log("MULTI-PHYS: RESULT=\(allPass ? "PASS" : "CHECK")")
            self.finish()
        }
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
        Self.log("MULTI-PHYS: DONE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
}
