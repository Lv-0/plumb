import AppKit
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AccessibilityPermission
//
// 模块角色：辅助功能（Accessibility）权限的检测与申请。
//
// 职责：
//   - ensureTrusted(prompt:)：检测是否已授权；prompt=true 时弹出系统授权对话框。
//   - awaitTrusted(timeout:onGranted:)：macOS 不提供"权限已授予"通知，故用定时轮询
//     直到授权或超时；授权后回调一次（用于权限在启动后才被授予时重新挂载 observer）。
//   - openSettings()：跳转到系统设置的辅助功能面板。
//
// 重要性：Accessibility 是读/写窗口位置的必需权限，未授权则居中/平铺功能完全不可用。
// ─────────────────────────────────────────────────────────────────────────────

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
