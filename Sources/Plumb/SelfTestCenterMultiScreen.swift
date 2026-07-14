import AppKit
import ApplicationServices

/// Physical multi-screen centering verification using a real TextEdit standard window.
/// Every placement and result assertion is read from CGWindow bounds, so AX coordinate-space
/// differences cannot turn a dialog or an off-screen frame into a false PASS.
///
/// Trigger: `defaults write com.comet.plumb selftestCenterMulti -bool true`, then launch the
/// signed app through Launch Services. Requires two displays, Screen Recording + AX access,
/// TextEdit running with a document window. Output: /tmp/cw_selftest_center_multi.log
@MainActor
final class SelfTestCenterMultiDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_center_multi.log"
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
            Self.log("CENTER-MULTI: screen=\(label) frame=\(screen.frame) visible=\(screen.visibleFrame) cg=\(SelfTestAXSupport.cgDisplayBounds(for: screen).map(String.init(describing:)) ?? "nil")")
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
            Self.log("CENTER-MULTI: candidate[\(index)] \(SelfTestAXSupport.describe(candidate))")
        }
        guard let selected = SelfTestAXSupport.selectStandardWindow(from: appElement) else {
            fail("no eligible AXStandardWindow (dialogs are never accepted)")
            finish()
            return
        }
        window = selected
        Self.log("CENTER-MULTI: selected \(SelfTestAXSupport.describe(selected))")
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
        Self.log("CENTER-MULTI: === center on \(label) ===")

        var requestedSize = CGSize(width: 400, height: 300)
        guard let sizeValue = AXValueCreate(.cgSize, &requestedSize),
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
        else {
            fail("\(label): unable to resize TextEdit test window")
            testScreen(at: index + 1, screens: screens)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let actualSize = self.window.axSize(kAXSizeAttribute as CFString) ?? requestedSize
            let candidates = SelfTestAXSupport.placementCandidates(for: screen, windowSize: actualSize)
            self.placeOnto(screen: screen, candidates: candidates, index: 0) { placed in
                guard placed else {
                    self.fail("\(label): all AX coordinate-space placement candidates failed")
                    self.testScreen(at: index + 1, screens: screens)
                    return
                }
                self.startCenterCase(
                    screen: screen,
                    expectedSize: actualSize,
                    index: index,
                    screens: screens
                )
            }
        }
    }

    private func placeOnto(
        screen: NSScreen,
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
            placeOnto(screen: screen, candidates: candidates, index: index + 1, completion: completion)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if let frame = SelfTestAXSupport.cgWindowFrame(self.window, pid: self.app.processIdentifier),
               SelfTestAXSupport.isOnScreen(frame, screen: screen)
            {
                Self.log("CENTER-MULTI: placement candidate[\(index)] accepted cg=\(frame)")
                completion(true)
            } else {
                self.placeOnto(screen: screen, candidates: candidates, index: index + 1, completion: completion)
            }
        }
    }

    private func startCenterCase(
        screen: NSScreen,
        expectedSize: CGSize,
        index: Int,
        screens: [NSScreen]
    ) {
        nextCaseID += 1
        let caseID = nextCaseID
        pendingCaseID = caseID
        let label = SelfTestAXSupport.displayLabel(for: screen, index: index)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        do {
            let result = try service.centerWindowElementAnimated(
                window,
                pid: app.processIdentifier,
                appElement: appElement
            ) { [weak self] outcome in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.completeCenterCase(
                        caseID: caseID,
                        outcome: outcome,
                        screen: screen,
                        expectedSize: expectedSize,
                        index: index,
                        screens: screens
                    )
                }
            }
            if result == .busy {
                pendingCaseID = nil
                fail("\(label): center service returned busy")
                testScreen(at: index + 1, screens: screens)
                return
            }
        } catch {
            pendingCaseID = nil
            fail("\(label): center threw \(error)")
            testScreen(at: index + 1, screens: screens)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, self.pendingCaseID == caseID else { return }
            self.pendingCaseID = nil
            self.fail("\(label): center completion timed out")
            self.service.abortActiveAnimations()
            self.testScreen(at: index + 1, screens: screens)
        }
    }

    private func completeCenterCase(
        caseID: Int,
        outcome: WindowAnimator.Outcome,
        screen: NSScreen,
        expectedSize: CGSize,
        index: Int,
        screens: [NSScreen]
    ) {
        guard pendingCaseID == caseID else { return }
        pendingCaseID = nil
        let label = SelfTestAXSupport.displayLabel(for: screen, index: index)
        guard outcome == .finished else {
            fail("\(label): center completion was \(outcome)")
            testScreen(at: index + 1, screens: screens)
            return
        }
        guard let visible = SelfTestAXSupport.cgVisibleFrame(for: screen) else {
            fail("\(label): unable to convert visible frame into CG coordinates")
            testScreen(at: index + 1, screens: screens)
            return
        }
        let expected = CGRect(
            x: visible.midX - expectedSize.width / 2,
            y: visible.midY - expectedSize.height / 2,
            width: expectedSize.width,
            height: expectedSize.height
        )
        verifyCenterCase(
            screen: screen,
            expected: expected,
            label: label,
            attempt: 0,
            index: index,
            screens: screens
        )
    }

    private func verifyCenterCase(
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
                fail("\(label): center mismatch after bounded retry actual=\(actual.map(String.init(describing:)) ?? "nil") expected=\(expected) stayedOnTarget=\(stayedOnTarget)")
                testScreen(at: index + 1, screens: screens)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.verifyCenterCase(
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
            Self.log("CENTER-MULTI: PASS \(label) actual=\(actual) expected=\(expected)")
        }
        testScreen(at: index + 1, screens: screens)
    }

    private func fail(_ message: String) {
        failures += 1
        Self.log("CENTER-MULTI: FAIL — \(message)")
    }

    private func finish() {
        let passed = failures == 0
        Self.log("CENTER-MULTI: RESULT=\(passed ? "PASS" : "FAIL") failures=\(failures)")
        let code: Int32 = passed ? 0 : 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(code) }
    }
}
