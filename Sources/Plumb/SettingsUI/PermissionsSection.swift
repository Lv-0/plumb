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
    /// 与 SettingsView 同源的设置绑定：改这里即触发其 `.onChange(of: settings) → store.save`，
    /// 避免另起数据源导致 stale 覆盖（详见 hideStatusBarIconCard 注释）。
    @Binding var hideStatusBarIcon: Bool

    @State private var accessibilityOK = false
    @State private var screenCaptureOK = false
    @State private var launchAtLogin: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.permissionsIntro)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 12) {
                    permissionRow(
                        title: L10n.accessibility,
                        granted: accessibilityOK,
                        symbol: "person.crop.circle.badge.checkmark",
                        action: { AccessibilityPermission.openSettings(); refresh() }
                    )
                    Divider()
                    permissionRow(
                        title: L10n.screenRecording,
                        granted: screenCaptureOK,
                        symbol: "rectangle.dashed.badge.record",
                        action: { ScreenCapturePermission.openSettings(); refresh() }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                // 不用 .glassEffect（窗口已是晶莹液态玻璃，叠 glass 会变磨砂）；
                // 极淡填充做卡片分区，保留窗口单一折射。
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )

                launchAtLoginCard
                hideStatusBarIconCard
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
                Text(granted ? L10n.granted : L10n.notGranted)
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .orange)
            }
            Spacer(minLength: 8)
            Button(L10n.openSettings, action: action)
                .buttonStyle(.bordered)
        }
    }

    private func refresh() {
        accessibilityOK = AccessibilityPermission.ensureTrusted(prompt: false)
        screenCaptureOK = ScreenCapturePermission.ensureAuthorized(prompt: false)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    /// 开机自启动独立卡片：图标 + 标题/说明 + 开关。视觉与权限卡片一致（极淡填充，不叠 glass）。
    private var launchAtLoginCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "power")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.launchAtLogin)
                    .foregroundStyle(.primary)
                Text(L10n.launchAtLoginHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            PillToggle(isOn: $launchAtLogin)
                .animation(.spring(duration: 0.32, bounce: 0.25), value: launchAtLogin)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .onChange(of: launchAtLogin) { _, isOn in
            toggleLaunchAtLogin(to: isOn)
        }
    }

    /// 切换开机自启动：以系统状态为准刷新；失败时回滚开关到真实值，保持一致且不崩溃。
    private func toggleLaunchAtLogin(to isOn: Bool) {
        do {
            if isOn { try LaunchAtLogin.enable() }
            else    { try LaunchAtLogin.disable() }
            launchAtLogin = LaunchAtLogin.isEnabled
        } catch {
            // 失败（如裸可执行环境）→ 回滚到真实状态。
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }

    /// 「隐藏菜单栏图标」独立卡片：视觉与开机自启动卡片一致。
    /// 说明文案即为逃生口用法——隐藏后连续两次打开 Plumb 可重新进入设置。
    ///
    /// 数据流：$hideStatusBarIcon 绑定自 SettingsView 的 settings，改它即触发其
    /// `.onChange(of: settings) → store.save(new)`，与本卡片共用唯一数据源，
    /// 避免另起 store 写入被随后的平铺/居中编辑 stale 覆盖。
    /// 仅在切换后额外发通知，让 AppDelegate 即时增/删菜单栏图标（save 已落盘，通知只负责触发 UI 反应）。
    private var hideStatusBarIconCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.hideStatusBarIcon)
                    .foregroundStyle(.primary)
                Text(L10n.hideStatusBarIconHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            PillToggle(isOn: $hideStatusBarIcon)
                .animation(.spring(duration: 0.32, bounce: 0.25), value: hideStatusBarIcon)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .onChange(of: hideStatusBarIcon) { _, _ in
            // 通知 AppDelegate 即时增/删菜单栏图标（设置已随 binding 落盘）。
            NotificationCenter.default.post(name: SettingsWindowNotifications.statusBarIconVisibilityChanged, object: nil)
        }
    }
}
