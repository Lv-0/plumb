import SwiftUI

/// 权限段：状态行 + 两个 recessed 按钮。
struct PermissionsSection: View {
    @State private var accessibilityOK = false
    @State private var screenCaptureOK = false

    var body: some View {
        Form {
            Section("辅助功能 / 屏幕录制") {
                Text(statusText)
                    .foregroundStyle(.secondary)

                Button("打开辅助功能设置…") {
                    AccessibilityPermission.openSettings()
                    refresh()
                }
                Button("打开屏幕录制设置…") {
                    ScreenCapturePermission.openSettings()
                    refresh()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private var statusText: String {
        "辅助功能：\(accessibilityOK ? "已授权 ✓" : "未授权")    屏幕录制：\(screenCaptureOK ? "已授权 ✓" : "未授权")"
    }

    private func refresh() {
        accessibilityOK = AccessibilityPermission.ensureTrusted(prompt: false)
        screenCaptureOK = ScreenCapturePermission.ensureAuthorized(prompt: false)
    }
}
