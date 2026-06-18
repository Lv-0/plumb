import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - TilingSection (SettingsUI)
//
// 模块角色：设置中"平铺"标签页的内容视图。
//
// 职责：
//   - 平铺总开关（绑定 settings.isEnabled）+ 边距滑块（绑定 settings.edgeMargin，
//     范围 minimumEdgeMargin...maximumEdgeMargin），共用一个 Liquid Glass 容器。
//   - 总开关未开启时滑块置灰、提示文案切换。
//   - 复用 AppListSection 渲染平铺白名单（selected = settings.tiledBundleIDs）。
//
// 关键历史：此前 settings.isEnabled 从未绑定到 UI（默认 false），导致 shouldTile()
// 永远返回 false——这是"平铺功能完全无法使用"的根因。
// ─────────────────────────────────────────────────────────────────────────────

/// 平铺段：顶部总开关 + 边距滑块（Liquid Glass）+ 应用列表。
/// 关键修复：此前 settings.isEnabled（平铺总开关）从未绑定到任何 UI，
/// 默认 false 导致 shouldTile() 永远返回 false —— 这是"平铺功能完全无法使用"的根因。
struct TilingSection: View {
    @Binding var settings: AppTilingSettings
    let apps: [InstalledAppInfo]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 顶部：总开关 + 边距滑块（共用一个 Liquid Glass 容器）
                VStack(alignment: .leading, spacing: 12) {
                    // 平铺总开关：绑定 settings.isEnabled，未开启则整个平铺功能不生效。
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用自动平铺")
                                .foregroundStyle(.primary)
                            Text("开启后，勾选下方应用时会自动平铺到屏幕。")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 12)
                        PillToggle(isOn: $settings.isEnabled)
                            .animation(.spring(duration: 0.32, bounce: 0.25), value: settings.isEnabled)
                    }

                    Divider().opacity(0.2)

                    // 边距滑块
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Text("边距")
                                .foregroundStyle(.primary)
                            Slider(value: $settings.edgeMargin,
                                   in: AppTilingSettings.minimumEdgeMargin...AppTilingSettings.maximumEdgeMargin)
                                .disabled(!settings.isEnabled)
                            Text("\(Int(settings.edgeMargin.rounded())) px")
                                .foregroundStyle(settings.isEnabled ? .secondary : .tertiary)
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                        Text("平铺时窗口与屏幕边缘之间的间距。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .opacity(settings.isEnabled ? 1.0 : 0.55)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    // 不用 .glassEffect（窗口已是晶莹液态玻璃，叠 glass 会变磨砂）；
                    // 极淡填充做卡片分区，保留窗口单一折射。
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )

                AppListSection(
                    footnote: settings.isEnabled
                        ? "勾选希望自动平铺的应用；未勾选的应用保持居中。"
                        : "请先在上方开启自动平铺。",
                    selected: $settings.tiledBundleIDs,
                    apps: apps
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}
