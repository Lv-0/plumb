import AppKit
import ApplicationServices

/// Cancellation handle for the long-running Accessibility trust poll.
///
/// `DispatchSourceTimer` does not provide structured cancellation to its caller. Keeping
/// the timer behind this small thread-safe handle lets `WindowEventObserver.stop()` own
/// the complete lifetime of a poll and prevents an old `start()` generation from
/// re-attaching the observer after it has been stopped.
final class AccessibilityTrustPollingHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var terminal = false

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !terminal
    }

    fileprivate func install(_ timer: DispatchSourceTimer) -> Bool {
        lock.lock()
        guard !terminal else {
            lock.unlock()
            timer.cancel()
            return false
        }
        self.timer = timer
        lock.unlock()
        return true
    }

    /// Moves the poll to a terminal state exactly once. The winning caller owns any
    /// associated callback; a concurrent/stale cancellation therefore suppresses it.
    @discardableResult
    fileprivate func finish() -> Bool {
        let timerToCancel: DispatchSourceTimer?
        lock.lock()
        guard !terminal else {
            lock.unlock()
            return false
        }
        terminal = true
        timerToCancel = timer
        timer = nil
        lock.unlock()
        timerToCancel?.cancel()
        return true
    }

    func cancel() {
        _ = finish()
    }

    deinit {
        cancel()
    }
}

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
    @discardableResult
    static func awaitTrusted(
        timeout: TimeInterval,
        interval: TimeInterval = 0.5,
        trustCheck: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        now: @escaping @Sendable () -> Date = { Date() },
        onGranted: @escaping @Sendable () -> Void
    ) -> AccessibilityTrustPollingHandle {
        let handle = AccessibilityTrustPollingHandle()
        // Already trusted: invoke immediately.
        if trustCheck() {
            if handle.finish() {
                onGranted()
            }
            return handle
        }

        DiagnosticLog.debug("awaitTrusted: start polling (timeout=\(timeout)s, interval=\(interval)s)")
        let deadline = now().addingTimeInterval(timeout)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        var polls = 0
        timer.setEventHandler { [weak handle] in
            guard let handle, handle.isActive else { return }
            polls += 1
            if trustCheck() {
                guard handle.finish() else { return }
                DiagnosticLog.debug("awaitTrusted: GRANTED after \(polls) polls")
                onGranted()
            } else if now() >= deadline {
                guard handle.finish() else { return }
                DiagnosticLog.debug("awaitTrusted: TIMEOUT after \(polls) polls — never granted")
            }
        }
        guard handle.install(timer) else { return handle }
        timer.resume()
        return handle
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
