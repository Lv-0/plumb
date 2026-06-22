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
//   - 文档类 App 选择器处理段（DocumentChooserSection）：仅显示已在平铺白名单内的 App，
//     让用户选择哪些 App 启用"选择器只居中、文档才平铺"的特殊处理。
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
                            Text(L10n.enableAutoTiling)
                                .foregroundStyle(.primary)
                            Text(L10n.enableAutoTilingHint)
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
                            Text(L10n.margin)
                                .foregroundStyle(.primary)
                            Slider(value: $settings.edgeMargin,
                                   in: AppTilingSettings.minimumEdgeMargin...AppTilingSettings.maximumEdgeMargin)
                                .disabled(!settings.isEnabled)
                            Text("\(Int(settings.edgeMargin.rounded())) px")
                                .foregroundStyle(settings.isEnabled ? .secondary : .tertiary)
                                .monospacedDigit()
                                .frame(width: 56, alignment: .trailing)
                        }
                        Text(L10n.marginHint)
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
                        ? L10n.tilingFootnoteOn
                        : L10n.tilingFootnoteOff,
                    selected: $settings.tiledBundleIDs,
                    apps: apps
                )

                // 文档类 App 选择器处理段：仅显示已在平铺白名单内的 App。
                DocumentChooserSection(
                    selected: $settings.documentChooserBundleIDs,
                    tiledBundleIDs: settings.tiledBundleIDs,
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DocumentChooserSection
//
// 模块角色：平铺设置中"文档类 App 选择器处理"段。
//
// 职责：
//   - 仅渲染【已在平铺白名单内】的 App（tiledBundleIDs ∩ installed apps），
//     避免给未平铺的 App 配置无意义的"选择器感知"选项。
//   - 绑定 settings.documentChooserBundleIDs：勾选的 App 启用"选择器只居中、
//     文档才平铺"的特殊处理（详见 WindowEventObserver.handle 的选择器分支）。
//   - 列表为空时（无 App 在平铺白名单）显示提示文案，引导用户先加入平铺列表。
//
// 复用 AppListSection：传入过滤后的 apps 列表，与上方平铺段的视觉/交互一致。
// ─────────────────────────────────────────────────────────────────────────────

struct DocumentChooserSection: View {
    @Binding var selected: Set<String>
    let tiledBundleIDs: Set<String>
    let apps: [InstalledAppInfo]

    /// 仅显示已在平铺白名单内的 App（bundle id 已归一化为小写存储）。
    private var tiledApps: [InstalledAppInfo] {
        apps.filter { tiledBundleIDs.contains($0.bundleID) }
    }

    var body: some View {
        if tiledApps.isEmpty {
            // 无可配置的 App：显示引导提示，不渲染列表（避免空搜索框的困惑）。
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.documentChooserTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(L10n.documentChooserFootnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(L10n.documentChooserEmptyHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            AppListSection(
                footnote: L10n.documentChooserFootnote,
                selected: $selected,
                apps: tiledApps
            )
        }
    }
}
