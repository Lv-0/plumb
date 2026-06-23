import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppListSection / CenteringSection (SettingsUI)
//
// 模块角色：居中段与平铺段共用的"应用列表 + 搜索"视图。
//
// 职责：
//   - 搜索框（Liquid Glass 作 ZStack 底层、allowsHitTesting(false)，TextField 在顶层独立
//     获得焦点——修复 .interactive 玻璃吞焦点的问题）。
//   - LazyVStack 渲染 AppListRow；选中的应用排在前面，切换开关时平滑重排。
//   - sortedFilteredApps：叠加搜索过滤与"选中在前+名称字母序"排序的纯计算。
//
// CenteringSection：把 AppListSection 放进 ScrollView 的居中段容器。
// 关键：直接使用 AppListSection 走 body（而非 .contentView 间接访问），否则会破坏
// SwiftUI 视图标识导致 @FocusState/@State 绑定失效。
// ─────────────────────────────────────────────────────────────────────────────

/// 居中/平铺段共用的“应用列表”：搜索框 + 药丸开关行，选中的应用排在前面。
struct AppListSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]
    /// 可选：判定某行是否应被置灰禁用（不可勾选 + 行内提示）。默认 nil = 全部可勾选。
    /// 用于「文档类 App」页：未加入平铺白名单的 App 置灰，因其选择器感知仅在平铺时才生效。
    var isRowDisabled: ((InstalledAppInfo) -> Bool)? = nil
    /// 是否显示「全部打开 / 全部关闭」批量操作行。默认 false，仅居中段传 true。
    /// 平铺白名单页与文档类 App 页不传，保持原样（零回归）。
    var showsBulkActions: Bool = false
    /// 可选：per-app 边距抽屉。非 nil 时，列表行使用可展开的 AppListRowExpandable
    ///（点击 app 下拉出边距滑块），并显示一行 per-app 边距说明脚注。
    /// 仅平铺白名单页传值；居中/文档页不传 → 仍用原 AppListRow（零回归）。
    var perAppMargins: Binding<[String: CGFloat]>? = nil
    var defaultMargin: CGFloat = AppTilingSettings.defaultEdgeMargin

    @State private var query: String = ""
    /// 搜索框焦点：显式 @FocusState。用于：
    ///   (a) 切换到该段时自动聚焦搜索框，用户可直接打字（UX 改进）；
    ///   (b) 确保搜索框的焦点生命周期由 SwiftUI 管理，不受外层玻璃/容器影响；
    ///   (c) 提供 selftest 可观测的"焦点可达"信号（确认 allowsHitTesting(false) 修复有效）。
    @FocusState private var searchFocused: Bool

    /// 过滤 + 排序：选中的排前面，再按名称字母序；叠加搜索过滤。
    private var sortedFilteredApps: [InstalledAppInfo] {
        AppListFilter.filterAndSort(
            apps: apps,
            query: query,
            selected: selected
        )
    }

    var body: some View {
        contentView
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 内容（不含 ScrollView）—— 供居中段直接使用；平铺段会放进它自己的 ScrollView。
    var contentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            // 批量操作行（仅居中段显示）：作用于当前搜索过滤后的可见列表。
            // 全部打开 = 并入可见 ID；全部关闭 = 移除可见 ID。空列表时两按钮置灰。
            if showsBulkActions {
                bulkActionsBar
            }

            // 搜索框：极淡半透明作 ZStack 底层（allowsHitTesting(false)），文本框在顶层独立
            // 获得焦点。不用 .glassEffect：窗口本身已是晶莹液态玻璃，这里再叠 glass 会变成
            // 磨砂糊状；仅用一层很淡的填充区分搜索框区域，保留窗口单一折射。
            // allowsHitTesting(false) 彻底排除该层参与命中测试，保证 TextField 一定能聚焦。
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .allowsHitTesting(false)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L10n.searchApps, text: $query)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($searchFocused)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 40)
            .onAppear {
                // 自动聚焦搜索框：用户切换到该段即可直接打字筛选。
                // 延后到下一 runloop，确保布局完成后再请求焦点，提高可靠性。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    searchFocused = true
                }
            }

            // 应用列表：选中在前 —— 切换开关时平滑重排。
            LazyVStack(spacing: 2) {
                ForEach(sortedFilteredApps, id: \.bundleID) { app in
                    if let perAppMargins {
                        // 平铺白名单页：可展开边距抽屉的行。
                        AppListRowExpandable(
                            app: app,
                            defaultMargin: defaultMargin,
                            isOn: Binding(
                                get: { selected.contains(app.bundleID) },
                                set: { on in
                                    if on { selected.insert(app.bundleID) }
                                    else { selected.remove(app.bundleID) }
                                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {}
                                }
                            ),
                            perAppMargins: perAppMargins,
                            isDisabled: isRowDisabled?(app) ?? false
                        )
                    } else {
                        // 默认：原 AppListRow（居中/文档页）。
                        AppListRow(app: app, isOn: Binding(
                            get: { selected.contains(app.bundleID) },
                            set: { on in
                                if on { selected.insert(app.bundleID) }
                                else { selected.remove(app.bundleID) }
                                // 触发排序动画
                                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {}
                            }
                        ), isDisabled: isRowDisabled?(app) ?? false)
                    }
                }
            }
            .padding(8)
            // 不用 .glassEffect（窗口已是晶莹液态玻璃，叠 glass 会变磨砂）；
            // 极淡填充仅做卡片分区，保留窗口单一折射。
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .animation(.spring(duration: 0.35, bounce: 0.15), value: selected)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// 批量操作行：「全部打开 / 全部关闭」两个胶囊按钮，作用于当前可见列表。
    /// 视觉与 SubTabPill 未选中态一致（极淡半透明胶囊），保持 Liquid Glass 语言统一。
    /// 按钮无选中态（一次性动作），固定用 .medium 字重。
    private var bulkActionsBar: some View {
        let visibleEmpty = sortedFilteredApps.isEmpty
        return HStack(spacing: 8) {
            BulkActionButton(title: L10n.bulkSelectAll) {
                let ids = sortedFilteredApps.map(\.bundleID)
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    selected.formUnion(ids)
                }
            }
            .disabled(visibleEmpty)

            BulkActionButton(title: L10n.bulkDeselectAll) {
                let ids = Set(sortedFilteredApps.map(\.bundleID))
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    selected.subtract(ids)
                }
            }
            .disabled(visibleEmpty)

            Spacer(minLength: 0)
        }
    }
}

/// 应用列表搜索过滤 + 排序的纯函数命名空间（无 MainActor 隔离，便于单测）。
///
/// 过滤策略：**仅按显示名匹配**。
///
/// 回归历史（为何不碰 bundle id）：
///   1. 最初 `app.bundleID.contains(q)` —— 反向域名前缀（`com.apple.` 等）几乎总含
///      常见字母，输入 "a" 几乎所有 Apple 应用都命中（bug：搜索 a 不过滤）。
///   2. 改成只比 bundle id 最后一段 —— 仍有漏洞：`com.mowglii.ItsycalApp`→`itsycalapp`、
///      `net.whatsapp.WhatsApp`→`whatsapp`，最后一段本身常含 "app" 等通用词，输入 "app"
///      会把名字里没有 app 的 Itsycal/WhatsApp 也带出来（bug：搜 app 出现 Itsycal）。
///
/// 对菜单栏居中/平铺工具而言，用户认知里只有"应用名"，bundle id 是内部标识。按 bundle id
/// 搜索对终端用户没有实际价值，反而持续制造"看似没过滤干净"的困惑。故彻底只按显示名过滤，
/// 简单、可测、符合用户心智。
enum AppListFilter {
    static func filterAndSort(
        apps: [InstalledAppInfo],
        query: String,
        selected: Set<String>
    ) -> [InstalledAppInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return apps
            .filter { app in
                if q.isEmpty { return true }
                return app.name.lowercased().contains(q)
            }
            .sorted { a, b in
                let aOn = selected.contains(a.bundleID)
                let bOn = selected.contains(b.bundleID)
                if aOn != bOn { return aOn && !bOn }
                return a.name.localizedLowercase < b.name.localizedLowercase
            }
    }
}

/// 居中段的滚动容器包装。
/// 关键修复：此前使用 `AppListSection(...).contentView`（计算属性间接访问），
/// 这会破坏 SwiftUI 的视图标识，导致 @FocusState/@State 绑定失效 → 搜索框无法聚焦。
/// 平铺段（TilingSection）直接使用 `AppListSection(...)`（走 body）则正常。
/// 现统一为直接使用 body，与平铺段一致。
struct CenteringSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]

    var body: some View {
        ScrollView {
            AppListSection(
                footnote: footnote,
                selected: $selected,
                apps: apps,
                showsBulkActions: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - BulkActionButton
//
// 批量操作胶囊按钮：视觉与 SubTabPill 未选中态一致（极淡半透明填充 + .medium 字重），
// 不叠 .glassEffect（窗口已是液态玻璃，叠 glass 会变磨砂）。一次性动作，无选中态。
// ─────────────────────────────────────────────────────────────────────────────

private struct BulkActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }
}
