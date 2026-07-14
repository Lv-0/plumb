import AppKit
import ApplicationServices

/// Physical multi-screen tiling verification using the real animated service.
/// It places one eligible TextEdit document window on every connected display, tiles it,
/// and compares authoritative CGWindow bounds against the exact per-screen target.
///
/// Trigger: `defaults write com.comet.plumb selftestMultiPhysical -bool true`, then launch
/// the signed app through Launch Services. Output: /tmp/cw_selftest_multi_phys.log
@MainActor
final class SelfTestMultiScreenPhysicalDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_multi_phys.log"
    private let insets = TileInsets(all: 16)
    private var service = WindowCenteringService()
    private var window: AXUIElement!
    private var app: NSRunningApplication!
    private var failures = 0
    private var nextCaseID = 0
    private var pendingCaseID: Int?

    private static func log(_ message: String) {
        print(message)
        guard let data = (message + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logPath),
           let handle = FileHandle(forWritingAtPath: logPath)
        {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
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
            fail("need at least 2 screens, found \(screens.count)")
            finish()
            return
        }
        for (index, screen) in screens.enumerated() {
            let label = SelfTestAXSupport.displayLabel(for: screen, index: index)
            Self.log("MULTI-PHYS: screen=\(label) frame=\(screen.frame) visible=\(screen.visibleFrame) cg=\(SelfTestAXSupport.cgDisplayBounds(for: screen).map { String(describing: $0) } ?? "nil")")
            if SelfTestAXSupport.displayID(for: screen) == nil || SelfTestAXSupport.cgVisibleFrame(for: screen) == nil {
                fail("screen \(label) has no display ID / CG visible frame")
            }
        }
        guard failures == 0 else {
            finish()
            return
        }

        guard let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.TextEdit"
        ).first else {
            fail("TextEdit is not running")
            finish()
            return
        }
        app = running
        app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.locateAndTest(screens: screens)
        }
    }

    private func locateAndTest(screens: [NSScreen]) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let candidates = appElement.axWindowElements(kAXWindowsAttribute as CFString)
        for (index, candidate) in candidates.enumerated() {
            Self.log("MULTI-PHYS: candidate[\(index)] \(SelfTestAXSupport.describe(candidate))")
        }
        guard let selected = SelfTestAXSupport.selectStandardWindow(from: appElement) else {
            fail("no eligible AXStandardWindow (dialogs are never accepted)")
            finish()
            return
        }
        window = selected
        Self.log("MULTI-PHYS: selected \(SelfTestAXSupport.describe(selected))")
        guard SelfTestAXSupport.cgWindowFrame(selected, pid: app.processIdentifier) != nil else {
            fail("selected window has no authoritative CGWindow bounds; check Screen Recording and AXWindowNumber")
            finish()
            return
        }
        testScreen(at: 0, screens: screens)
    }

    private func testScreen(at index: Int, screens: [NSScreen]) {
        guard index < screens.count else {
            finish()
            return
        }
        let screen = screens[index]
        let label = SelfTestAXSupport.displayLabel(for: screen, index: index)
        Self.log("MULTI-PHYS: === tile on \(label) ===")

        // Move a small seed window to the destination first. macOS constrains a size write
        // against the window's current display, so asking for an external-screen width while
        // the window is still on the built-in panel would invalidate the canary setup.
        let seedSize = CGSize(width: 400, height: 300)
        var writableSize = seedSize
        guard let sizeValue = AXValueCreate(.cgSize, &writableSize),
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
        else {
            fail("\(label): unable to resize TextEdit seed window")
            testScreen(at: index + 1, screens: screens)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let actualSize = self.window.axSize(kAXSizeAttribute as CFString) ?? seedSize
            let seedFrame = CGRect(
                x: screen.visibleFrame.midX - actualSize.width / 2,
                y: screen.visibleFrame.midY - actualSize.height / 2,
                width: actualSize.width,
                height: actualSize.height
            )
            guard let expectedSeed = SelfTestAXSupport.cgFrame(fromCocoa: seedFrame, on: screen) else {
                self.fail("\(label): unable to convert seed frame into CG coordinates")
                self.testScreen(at: index + 1, screens: screens)
                return
            }
            self.placeOnto(
                screen: screen,
                expected: expectedSeed,
                candidates: SelfTestAXSupport.placementCandidates(forCocoaFrame: seedFrame, on: screen),
                index: 0
            ) { placed in
                guard placed else {
                    self.fail("\(label): unable to place seed window on destination display")
                    self.testScreen(at: index + 1, screens: screens)
                    return
                }
                self.startTileCase(screen: screen, index: index, screens: screens)
            }
        }
    }

    private func placeOnto(
        screen: NSScreen,
        expected: CGRect,
        candidates: [CGPoint],
        index: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard index < candidates.count else {
            completion(false)
            return
        }
        var origin = candidates[index]
        guard let value = AXValueCreate(.cgPoint, &origin),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
        else {
            placeOnto(
                screen: screen,
                expected: expected,
                candidates: candidates,
                index: index + 1,
                completion: completion
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if let frame = SelfTestAXSupport.cgWindowFrame(self.window, pid: self.app.processIdentifier),
               SelfTestAXSupport.isOnScreen(frame, screen: screen),
               SelfTestAXSupport.framesMatch(frame, expected, tolerance: 6)
            {
                Self.log("MULTI-PHYS: placement candidate[\(index)] accepted cg=\(frame)")
                completion(true)
            } else {
                self.placeOnto(
                    screen: screen,
                    expected: expected,
                    candidates: candidates,
                    index: index + 1,
                    completion: completion
                )
            }
        }
    }

    private func startTileCase(screen: NSScreen, index: Int, screens: [NSScreen]) {
        nextCaseID += 1
        let caseID = nextCaseID
        pendingCaseID = caseID
        let label = SelfTestAXSupport.displayLabel(for: screen, index: index)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        do {
            let result = try service.tileWindowElementAnimated(
                window,
                pid: app.processIdentifier,
                appElement: appElement,
                insets: insets
            ) { [weak self] outcome in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self?.completeTileCase(
                        caseID: caseID,
                        outcome: outcome,
                        screen: screen,
                        index: index,
                        screens: screens
                    )
                }
            }
            if result == .busy {
                pendingCaseID = nil
                fail("\(label): tile service returned busy")
                testScreen(at: index + 1, screens: screens)
                return
            }
        } catch {
            pendingCaseID = nil
            fail("\(label): tile threw \(error)")
            testScreen(at: index + 1, screens: screens)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self, self.pendingCaseID == caseID else { return }
            self.pendingCaseID = nil
            self.fail("\(label): tile completion timed out")
            self.service.abortActiveAnimations()
            self.testScreen(at: index + 1, screens: screens)
        }
    }

    private func completeTileCase(
        caseID: Int,
        outcome: WindowAnimator.Outcome,
        screen: NSScreen,
        index: Int,
        screens: [NSScreen]
    ) {
        guard pendingCaseID == caseID else { return }
        pendingCaseID = nil
        let label = SelfTestAXSupport.displayLabel(for: screen, index: index)
        guard outcome == .finished else {
            fail("\(label): tile completion was \(outcome)")
            testScreen(at: index + 1, screens: screens)
            return
        }
        let cocoaTarget = WindowGeometry.tiledFrame(visibleFrame: screen.visibleFrame, insets: insets)
        guard let expected = SelfTestAXSupport.cgFrame(fromCocoa: cocoaTarget, on: screen) else {
            fail("\(label): unable to convert final target into CG coordinates")
            testScreen(at: index + 1, screens: screens)
            return
        }
        verifyTileCase(
            screen: screen,
            expected: expected,
            label: label,
            attempt: 0,
            index: index,
            screens: screens
        )
    }

    /// AX size changes can become visible before the matching WindowServer record does.
    /// Poll the authoritative CG frame for a bounded 1.5 seconds, without relaxing the
    /// exact target predicate or starting the next display case in the meantime.
    private func verifyTileCase(
        screen: NSScreen,
        expected: CGRect,
        label: String,
        attempt: Int,
        index: Int,
        screens: [NSScreen]
    ) {
        let actual = SelfTestAXSupport.cgWindowFrame(window, pid: app.processIdentifier)
        let geometryMatches = actual.map {
            SelfTestAXSupport.framesMatch($0, expected, tolerance: 6)
        } ?? false
        let stayedOnTarget = actual.map {
            SelfTestAXSupport.isOnScreen($0, screen: screen)
        } ?? false
        guard geometryMatches && stayedOnTarget else {
            guard attempt < 10 else {
                fail("\(label): tile mismatch after bounded retry actual=\(actual.map(String.init(describing:)) ?? "nil") expected=\(expected) stayedOnTarget=\(stayedOnTarget)")
                testScreen(at: index + 1, screens: screens)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.verifyTileCase(
                    screen: screen,
                    expected: expected,
                    label: label,
                    attempt: attempt + 1,
                    index: index,
                    screens: screens
                )
            }
            return
        }
        if let actual {
            Self.log("MULTI-PHYS: PASS \(label) actual=\(actual) expected=\(expected)")
        }
        testScreen(at: index + 1, screens: screens)
    }

    private func fail(_ message: String) {
        failures += 1
        Self.log("MULTI-PHYS: FAIL — \(message)")
    }

    private func finish() {
        let passed = failures == 0
        Self.log("MULTI-PHYS: RESULT=\(passed ? "PASS" : "FAIL") failures=\(failures)")
        let code: Int32 = passed ? 0 : 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(code) }
    }
}
