import AppKit
import ApplicationServices

enum AccessibilityPermission {
    static func ensureTrusted(prompt: Bool) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }

        return AXIsProcessTrusted()
    }

    /// Polls for the Accessibility permission until it is granted or the timeout elapses.
    /// `onGranted` is invoked exactly once on the main queue when the permission becomes available.
    /// macOS does not post a notification when Accessibility trust changes, so polling is the
    /// supported way to detect a user granting it after launch.
    static func awaitTrusted(timeout: TimeInterval, interval: TimeInterval = 0.5, onGranted: @escaping () -> Void) {
        // Already trusted: invoke immediately.
        if AXIsProcessTrusted() {
            onGranted()
            return
        }

        DiagnosticLog.debug("awaitTrusted: start polling (timeout=\(timeout)s, interval=\(interval)s)")
        let deadline = Date().addingTimeInterval(timeout)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        var polls = 0
        timer.setEventHandler {
            polls += 1
            if AXIsProcessTrusted() {
                timer.cancel()
                DiagnosticLog.debug("awaitTrusted: GRANTED after \(polls) polls")
                onGranted()
            } else if Date() >= deadline {
                timer.cancel()
                DiagnosticLog.debug("awaitTrusted: TIMEOUT after \(polls) polls — never granted")
            }
        }
        timer.resume()
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
