import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - TilingSection (SettingsUI)
//
// 模块角色：设置中"平铺"标签页的内容视图。
//
// 布局：顶部固定卡片（总开关 + 边距滑块）+ 胶囊子标签 + 左右可切换的双页内容区。
//   - 顶部卡片两页都可见，属于全局配置。
//   - 左页「平铺应用列表」= AppListSection（绑定 tiledBundleIDs）。
//   - 右页「文档类 App」= DocumentChooserSection（绑定 documentChooserBundleIDs）。
//   - 子标签切换时内容区横向滑动（.move 过渡），与主标签栏切换一致。
//
// 关键历史：此前 settings.isEnabled 从未绑定到 UI（默认 false），导致 shouldTile()
// 永远返回 false——这是"平铺功能完全无法使用"的根因。
// ─────────────────────────────────────────────────────────────────────────────

struct TilingSection: View {
    @Binding var settings: AppTilingSettings
    let apps: [InstalledAppInfo]

    /// 当前子页。进入「平铺」标签页时默认左页。
    /// 注意：切到其他主标签页再切回时，SettingsView 的 detailContainer 用 .id(section)
    /// 重建本视图，故 subPage 会回到默认左页——这是预期行为。
    @State private var subPage: SubPage = .allowlist

    var body: some View {
        VStack(spacing: 0) {
            // 顶部固定卡片：总开关 + 边距滑块（两页都可见，全局配置）。
            headerCard
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

            // 胶囊子标签栏。
            subTabBar
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            // 内容区：根据 subPage 显示对应页，横向滑动过渡。
            subPageContainer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 顶部固定卡片

    /// 总开关 + 边距滑块，共用一个 Liquid Glass 风格容器。
    private var headerCard: some View {
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
    }

    // MARK: - 子标签栏

    /// 两个胶囊子标签，复用主标签栏的视觉语言但更小更轻。
    private var subTabBar: some View {
        HStack(spacing: 8) {
            ForEach(SubPage.allCases, id: \.self) { page in
                SubTabPill(
                    title: page.title,
                    isSelected: subPage == page
                ) {
                    // 横向滑动过渡：点右侧→内容向左滑（新页从 .trailing 进入）；点左侧→反向。
                    let direction = pageOrder(for: page) > pageOrder(for: subPage)
                    withAnimation(.spring(duration: 0.35, bounce: 0.12)) {
                        lastDirectionForward = direction
                        subPage = page
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 缓存上一次切换方向，用于决定 .move(edge:)。
    /// true = 向右翻页（左→右），新页从 trailing 进入；false = 向左翻页（右→左），新页从 leading 进入。
    @State private var lastDirectionForward: Bool = true

    /// subPage 在 CaseIterable 中的下标，用于判断切换方向。
    private func pageOrder(for page: SubPage) -> Int {
        SubPage.allCases.firstIndex(of: page) ?? 0
    }

    // MARK: - 内容区

    @ViewBuilder
    private var subPageContainer: some View {
        // 各子页（AppListSection / DocumentChooserSection）本身不含 ScrollView，
        // 这里统一包裹，使应用列表可滚动；headerCard 与 subTabBar 固定在顶部不动。
        ScrollView {
            ZStack {
                switch subPage {
                case .allowlist:
                    // 平铺应用列表（白名单）。传入 perAppMargins 绑定，使行可展开边距抽屉。
                    // 用脚注提示用户：点击 app 可单独设置边距；未设置的使用默认边距。
                    AppListSection(
                        footnote: settings.isEnabled
                            ? L10n.perAppMarginHint
                            : L10n.tilingFootnoteOff,
                        selected: $settings.tiledBundleIDs,
                        apps: apps,
                        perAppMargins: $settings.perAppMargins,
                        defaultMargin: settings.edgeMargin
                    )
                    .transition(lastDirectionForward ? .move(edge: .trailing) : .move(edge: .leading))
                case .document:
                    // 文档类 App 选择器感知配置。
                    DocumentChooserSection(
                        selected: $settings.documentChooserBundleIDs,
                        tiledBundleIDs: settings.tiledBundleIDs,
                        apps: apps
                    )
                    .transition(lastDirectionForward ? .move(edge: .trailing) : .move(edge: .leading))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .scrollContentBackground(.hidden)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SubPage
// ─────────────────────────────────────────────────────────────────────────────

/// 平铺标签页内的两个子页。
private enum SubPage: String, CaseIterable {
    case allowlist   // 左页：平铺应用列表
    case document    // 右页：文档类 App

    var title: String {
        switch self {
        case .allowlist: return L10n.tilingSubtabAllowlist
        case .document:  return L10n.tilingSubtabDocument
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SubTabPill
//
// 胶囊子标签：复用主标签栏 TabPill 的视觉语言（选中=强调色填充、未选中=极淡半透明），
// 但字号/内边距更小，与主标签形成层级区分。
// ─────────────────────────────────────────────────────────────────────────────

private struct SubTabPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(Color.accentColor)
                      : AnyShapeStyle(Color.primary.opacity(0.06)))
        }
        .animation(.spring(duration: 0.32, bounce: 0.18), value: isSelected)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DocumentChooserSection
//
// 模块角色：平铺标签页右页「文档类 App」内容。
//
// 职责：
//   - 渲染【全部已安装 App】（与左页白名单一致），让 Excel/Word/Numbers/Pages 等
//     可被搜索与勾选。
//   - 对未加入平铺白名单的 App：行置灰、开关不可点、显示「先加入平铺列表」提示。
//     原因：选择器感知仅在 App 被平铺时才生效（handle() 的 shouldTile 前置条件），
//     故未平铺时开启它无意义；但仍显示出来，便于用户发现并先去左页加入白名单。
//   - 绑定 settings.documentChooserBundleIDs：勾选的 App 启用"选择器只居中、
//     文档才平铺"的特殊处理（详见 WindowEventObserver.handle 的选择器分支）。
//
// 复用 AppListSection：传入全部 apps + isRowDisabled 谓词，与左页视觉一致。
// ─────────────────────────────────────────────────────────────────────────────

struct DocumentChooserSection: View {
    @Binding var selected: Set<String>
    let tiledBundleIDs: Set<String>
    let apps: [InstalledAppInfo]

    var body: some View {
        if apps.isEmpty {
            // 极少见：无任何已安装 App 被扫描到。显示脚注 + 引导提示。
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.documentChooserFootnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(L10n.documentChooserEmptyHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            AppListSection(
                footnote: L10n.documentChooserFootnote,
                selected: $selected,
                apps: apps,
                // 未加入平铺白名单的 App 置灰（bundle id 已归一化为小写存储）。
                isRowDisabled: { !tiledBundleIDs.contains($0.bundleID) }
            )
        }
    }
}
