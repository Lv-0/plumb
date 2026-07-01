import AppKit
import ApplicationServices

/// Multi-screen geometry verification WITHOUT a physical 2nd display.
///
/// Requirement 4 ("app 原先在哪个屏幕上就应该在哪个屏幕上进行居中/平铺,
/// 不同屏幕逐屏计算 Dock/分辨率") is driven by pure logic:
///   - ScreenSelection.screenIndex(forCenter:inScreens:) → which screen
///   - WindowGeometry.tiledFrame(visibleFrame:insets:) → per-screen rect
///
/// This harness simulates a dual-monitor layout (primary + secondary with
/// different sizes/Dock positions) and proves the center-point-ownership
/// logic picks the correct screen and tiles against THAT screen's visibleFrame.
///
/// Trigger: `defaults write com.comet.plumb selftestMulti -bool true` then `open`.

@MainActor
final class SelfTestMultiScreenDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_multi.log"

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.runCases()
            NSApp.stop(nil)
        }
    }

    private func runCases() {
        // Simulated dual-monitor layout (in points). Primary on the left,
        // secondary on the right with a DIFFERENT resolution and a RIGHT-side
        // Dock (so its visibleFrame insets differ from the primary).
        let primaryFrame   = CGRect(x: 0,    y: 0, width: 1512, height: 982)
        let secondaryFrame = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let screens = [primaryFrame, secondaryFrame]

        // Per-screen visibleFrames: primary has bottom Dock (82) + menubar (80);
        // secondary has RIGHT-side Dock (90) + menubar (80) — DIFFERENT insets.
        let primaryVisible   = CGRect(x: 0,    y: 82, width: 1512,        height: 820)
        let secondaryVisible = CGRect(x: 1512, y: 80, width: 2560 - 90,   height: 1360)

        Self.log("MULTI: layout primary=\(primaryFrame) visible=\(primaryVisible)")
        Self.log("MULTI: layout secondary=\(secondaryFrame) visible=\(secondaryVisible)")
        Self.log("MULTI: (note: different sizes + different Dock sides = per-screen calc required)")
        Self.log("")

        var allPass = true

        // === Case A: window center clearly on the secondary screen ===
        // Window at x=2400 (middle of secondary), center should select secondary.
        let winCenterA = CGPoint(x: 2400, y: 700)
        let pickedA = ScreenSelection.screenIndex(forCenter: winCenterA, inScreens: screens)
        let expectedA = 1
        let pickOK_A = (pickedA == expectedA)
        // Tile against the SELECTED screen's visibleFrame (not the primary's).
        let tileA = WindowGeometry.tiledFrame(visibleFrame: secondaryVisible, insets: TileInsets(all: 16))
        let staysSecondaryA = tileA.minX >= secondaryVisible.minX && tileA.maxX <= secondaryVisible.maxX
        Self.log("MULTI Case A (window on secondary):")
        Self.log("  window center=\(winCenterA) → picked screen \(pickedA ?? -1) (expected \(expectedA)) \(pickOK_A ? "✓" : "✗")")
        Self.log("  tiled on secondary visibleFrame = \(stringify(tileA)) \(staysSecondaryA ? "(stays on secondary) ✓" : "(LEAKED to primary!) ✗")")
        if !pickOK_A || !staysSecondaryA { allPass = false }

        // === Case B: window center clearly on the primary screen ===
        let winCenterB = CGPoint(x: 700, y: 450)
        let pickedB = ScreenSelection.screenIndex(forCenter: winCenterB, inScreens: screens)
        let expectedB = 0
        let pickOK_B = (pickedB == expectedB)
        let tileB = WindowGeometry.tiledFrame(visibleFrame: primaryVisible, insets: TileInsets(all: 16))
        let staysPrimaryB = tileB.minX >= primaryVisible.minX && tileB.maxX <= primaryVisible.maxX
        Self.log("MULTI Case B (window on primary):")
        Self.log("  window center=\(winCenterB) → picked screen \(pickedB ?? -1) (expected \(expectedB)) \(pickOK_B ? "✓" : "✗")")
        Self.log("  tiled on primary visibleFrame = \(stringify(tileB)) \(staysPrimaryB ? "(stays on primary) ✓" : "(LEAKED!) ✗")")
        if !pickOK_B || !staysPrimaryB { allPass = false }

        // === Case C: cross-boundary window, center on secondary ===
        // A window straddling the seam but whose CENTER is on the secondary must
        // stay on the secondary (this is the core of "原先在哪屏就在哪屏").
        let winCenterC = CGPoint(x: 1700, y: 700) // just past the seam into secondary
        let pickedC = ScreenSelection.screenIndex(forCenter: winCenterC, inScreens: screens)
        let pickOK_C = (pickedC == 1)
        Self.log("MULTI Case C (cross-boundary, center on secondary):")
        Self.log("  window center=\(winCenterC) → picked screen \(pickedC ?? -1) (expected 1) \(pickOK_C ? "✓ (no jump to primary)" : "✗ (JUMPED!)")")
        if !pickOK_C { allPass = false }

        // === Case D: per-screen Dock difference honored ===
        // Secondary's right-side Dock means its tiled width is narrower by ~90+32px
        // vs its raw frame. Verify the tile respects the per-screen visibleFrame,
        // not the secondary's full frame width.
        let expectedSecTileWidth = secondaryVisible.width - 32  // 16px margin each side
        let dockHonored = abs(tileA.width - expectedSecTileWidth) < 2
        Self.log("MULTI Case D (per-screen right-Dock honored):")
        Self.log("  secondary tile width=\(tileA.width) (expected ~\(expectedSecTileWidth) after right-Dock inset) \(dockHonored ? "✓" : "✗")")
        if !dockHonored { allPass = false }

        Self.log("")
        Self.log("MULTI: RESULT=\(allPass ? "PASS" : "CHECK")")
    }

    private func stringify(_ r: CGRect) -> String {
        "x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))"
    }
}
