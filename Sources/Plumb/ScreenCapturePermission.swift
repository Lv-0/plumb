import AppKit
import CoreGraphics

enum ScreenCapturePermission {
    static func ensureAuthorized(prompt: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        if prompt {
            return CGRequestScreenCaptureAccess()
        }
        return false
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
