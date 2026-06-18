import AppKit
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ScreenCapturePermission
//
// 模块角色：屏幕录制（Screen Recording）权限的检测与申请。
//
// 职责：
//   - ensureAuthorized(prompt:)：检测是否已授权；prompt=true 时发起申请。
//   - openSettings()：跳转到系统设置的屏幕录制面板。
//
// 重要性：可选权限。授权后可用 CGWindowList API 作为辅助信号，显著提升多显示器 /
// 复杂布局下窗口坐标空间识别的稳定性（见 WindowCenteringService.detectWindowContextUsingCG）。
// 未授权时回退到纯 AX 推断，仍可工作但多屏下可能不稳定。
// ─────────────────────────────────────────────────────────────────────────────

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
