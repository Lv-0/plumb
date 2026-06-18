import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PermissionsSection (SettingsUI)
//
// 模块角色：设置中"权限"标签页的内容视图。
//
// 职责：展示辅助功能与屏幕录制两项权限的当前状态（已授权/未授权），并提供"打开设置…"
// 按钮跳转对应系统设置面板；点击按钮后立即 refresh() 重读状态。
//
// 说明：未授权仅为降级——辅助功能缺失则居中/平铺不可用；屏幕录制缺失则多屏坐标识别
// 可能不稳定（详见 AccessibilityPermission / ScreenCapturePermission 模块头）。
// ─────────────────────────────────────────────────────────────────────────────

/// 权限段：状态行 + 两个按钮，整体放在 Liquid Glass 容器里。
struct PermissionsSection: View {
    @State private var accessibilityOK = false
    @State private var screenCaptureOK = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Plumb 需要以下权限才能控制窗口位置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 12) {
                    permissionRow(
                        title: "辅助功能",
                        granted: accessibilityOK,
                        symbol: "person.crop.circle.badge.checkmark",
                        action: { AccessibilityPermission.openSettings(); refresh() }
                    )
                    Divider()
                    permissionRow(
                        title: "屏幕录制",
                        granted: screenCaptureOK,
                        symbol: "rectangle.dashed.badge.record",
                        action: { ScreenCapturePermission.openSettings(); refresh() }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .onAppear { refresh() }
    }

    private func permissionRow(title: String, granted: Bool, symbol: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(granted ? "已授权" : "未授权")
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .orange)
            }
            Spacer(minLength: 8)
            Button("打开设置…", action: action)
                .buttonStyle(.bordered)
        }
    }

    private func refresh() {
        accessibilityOK = AccessibilityPermission.ensureTrusted(prompt: false)
        screenCaptureOK = ScreenCapturePermission.ensureAuthorized(prompt: false)
    }
}
