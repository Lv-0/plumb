import AppKit
import ApplicationServices

/// Pure descriptor used to keep the self-test window-selection rule unit-testable.
struct SelfTestWindowDescriptor: Equatable {
    let role: String?
    let subrole: String?
    let size: CGSize
    let isMinimized: Bool
    let isModal: Bool
}

enum SelfTestWindowSelectionPolicy {
    static let minimumSize = CGSize(width: 200, height: 150)

    static func preferredIndex(in candidates: [SelfTestWindowDescriptor]) -> Int? {
        candidates.indices
            .filter { index in
                let candidate = candidates[index]
                return candidate.role == (kAXWindowRole as String) &&
                    candidate.subrole == (kAXStandardWindowSubrole as String) &&
                    !candidate.isMinimized &&
                    !candidate.isModal &&
                    candidate.size.width >= minimumSize.width &&
                    candidate.size.height >= minimumSize.height
            }
            .max { lhs, rhs in
                let left = candidates[lhs].size
                let right = candidates[rhs].size
                return left.width * left.height < right.width * right.height
            }
    }
}

/// Shared runtime evidence helpers for physical-display self-tests. All outcome checks use
/// CGWindow/CGDisplay bounds in the same top-left global space; raw AX positions are never
/// compared directly with Cocoa `NSScreen.frame`.
enum SelfTestAXSupport {
    static func selectStandardWindow(from appElement: AXUIElement) -> AXUIElement? {
        let windows = appElement.axWindowElements(kAXWindowsAttribute as CFString)
        let descriptors = windows.map(descriptor(for:))
        guard let index = SelfTestWindowSelectionPolicy.preferredIndex(in: descriptors) else {
            return nil
        }
        return windows[index]
    }

    static func descriptor(for window: AXUIElement) -> SelfTestWindowDescriptor {
        SelfTestWindowDescriptor(
            role: window.axString(kAXRoleAttribute as CFString),
            subrole: window.axString(kAXSubroleAttribute as CFString),
            size: window.axSize(kAXSizeAttribute as CFString) ?? .zero,
            isMinimized: window.axBool(kAXMinimizedAttribute as CFString) ?? false,
            isModal: window.axBool(kAXModalAttribute as CFString) ?? false
        )
    }

    static func describe(_ window: AXUIElement) -> String {
        let descriptor = descriptor(for: window)
        let title = window.axString(kAXTitleAttribute as CFString) ?? ""
        let number = window.axPositiveInteger("AXWindowNumber" as CFString).map(String.init) ?? "nil"
        return "role=\(descriptor.role ?? "nil") subrole=\(descriptor.subrole ?? "nil") " +
            "title=\(title.debugDescription) size=\(descriptor.size) minimized=\(descriptor.isMinimized) " +
            "modal=\(descriptor.isModal) windowNumber=\(number)"
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func displayLabel(for screen: NSScreen, index: Int? = nil) -> String {
        let prefix: String
        if let displayID = displayID(for: screen) {
            prefix = CGDisplayIsBuiltin(displayID) != 0 ? "BUILT-IN" : "EXTERNAL"
        } else {
            prefix = "UNKNOWN"
        }
        return index.map { "\(prefix)(\($0))" } ?? prefix
    }

    static func cgDisplayBounds(for screen: NSScreen) -> CGRect? {
        displayID(for: screen).map(CGDisplayBounds)
    }

    static func cgVisibleFrame(for screen: NSScreen) -> CGRect? {
        cgFrame(fromCocoa: screen.visibleFrame, on: screen)
    }

    static func cgFrame(fromCocoa cocoa: CGRect, on screen: NSScreen) -> CGRect? {
        guard let displayBounds = cgDisplayBounds(for: screen) else { return nil }
        let primaryTopY = NSScreen.screens.first(where: {
            abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5
        })?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        return CGRect(
            x: displayBounds.minX + (cocoa.minX - screen.frame.minX),
            y: primaryTopY - cocoa.maxY,
            width: cocoa.width,
            height: cocoa.height
        )
    }

    static func cgWindowFrame(_ window: AXUIElement, pid: pid_t) -> CGRect? {
        if let rawNumber = window.axPositiveInteger("AXWindowNumber" as CFString),
           (1...Int(UInt32.max)).contains(rawNumber),
           let list = CGWindowListCopyWindowInfo(
               [.optionIncludingWindow],
               CGWindowID(UInt32(rawNumber))
           ) as? [[String: Any]],
           let frame = cgFrame(from: list.first, ownerPID: pid)
        {
            return frame
        }

        // TextEdit and some Office builds omit AXWindowNumber. Fall back only when the
        // PID/layer/size evidence identifies one on-screen CG window; an exact title match
        // may disambiguate equal-sized document windows. Ambiguity is a hard harness failure.
        guard let expectedSize = window.axSize(kAXSizeAttribute as CFString),
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly],
                  kCGNullWindowID
              ) as? [[String: Any]]
        else { return nil }
        let candidates: [(info: [String: Any], frame: CGRect)] = list.compactMap { info in
            guard let frame = cgFrame(from: info, ownerPID: pid),
                  abs(frame.width - expectedSize.width) <= 4,
                  abs(frame.height - expectedSize.height) <= 4
            else { return nil }
            return (info, frame)
        }
        let title = window.axString(kAXTitleAttribute as CFString) ?? ""
        if !title.isEmpty {
            let titleMatches = candidates.filter {
                ($0.info[kCGWindowName as String] as? String) == title
            }
            if titleMatches.count == 1 {
                return titleMatches[0].frame
            }
        }
        return candidates.count == 1 ? candidates[0].frame : nil
    }

    private static func cgFrame(from info: [String: Any]?, ownerPID: pid_t) -> CGRect? {
        guard let info,
              info[kCGWindowOwnerPID as String] as? Int == Int(ownerPID),
              info[kCGWindowLayer as String] as? Int == 0,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    static func isOnScreen(_ frame: CGRect, screen: NSScreen) -> Bool {
        guard let displayBounds = cgDisplayBounds(for: screen) else { return false }
        return displayBounds.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    static func framesMatch(_ actual: CGRect, _ expected: CGRect, tolerance: CGFloat = 6) -> Bool {
        abs(actual.minX - expected.minX) <= tolerance &&
            abs(actual.minY - expected.minY) <= tolerance &&
            abs(actual.maxX - expected.maxX) <= tolerance &&
            abs(actual.maxY - expected.maxY) <= tolerance
    }

    /// Candidate AX origins for the four coordinate conventions supported by production.
    /// The caller writes each candidate and verifies success through CGWindow bounds.
    static func placementCandidates(for screen: NSScreen, windowSize: CGSize) -> [CGPoint] {
        guard let cgDisplay = cgDisplayBounds(for: screen),
              let cgVisible = cgVisibleFrame(for: screen)
        else { return [] }

        let cocoaVisible = screen.visibleFrame
        let globalTopLeft = CGPoint(
            x: cgVisible.midX - windowSize.width / 2,
            y: cgVisible.midY - windowSize.height / 2
        )
        let globalBottomLeft = CGPoint(
            x: cocoaVisible.midX - windowSize.width / 2,
            y: cocoaVisible.midY - windowSize.height / 2
        )
        let localTopLeft = CGPoint(
            x: globalTopLeft.x - cgDisplay.minX,
            y: globalTopLeft.y - cgDisplay.minY
        )
        let localBottomLeft = CGPoint(
            x: globalBottomLeft.x - screen.frame.minX,
            y: globalBottomLeft.y - screen.frame.minY
        )
        return [globalTopLeft, globalBottomLeft, localTopLeft, localBottomLeft]
    }

    /// Candidate AX origins for an exact Cocoa frame. Physical self-tests use this to seed a
    /// window on the destination display before asking production layout code to move it.
    static func placementCandidates(forCocoaFrame frame: CGRect, on screen: NSScreen) -> [CGPoint] {
        guard let cgDisplay = cgDisplayBounds(for: screen),
              let cgFrame = cgFrame(fromCocoa: frame, on: screen)
        else { return [] }
        let globalTopLeft = cgFrame.origin
        let globalBottomLeft = frame.origin
        let localTopLeft = CGPoint(
            x: globalTopLeft.x - cgDisplay.minX,
            y: globalTopLeft.y - cgDisplay.minY
        )
        let localBottomLeft = CGPoint(
            x: globalBottomLeft.x - screen.frame.minX,
            y: globalBottomLeft.y - screen.frame.minY
        )
        return [globalTopLeft, globalBottomLeft, localTopLeft, localBottomLeft]
    }
}
