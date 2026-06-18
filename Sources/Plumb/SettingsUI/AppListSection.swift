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

            // 搜索框：Liquid Glass 仅作为 ZStack 底层（.allowsHitTesting(false)），
            // 文本框在最上层独立捕获点击/焦点。
            // 此前用 .glassEffect().interactive 直接包裹 TextField 导致无法聚焦；
            // 改用显式 ZStack + allowsHitTesting(false) 彻底排除玻璃层参与命中测试，
            // 保证 TextField 一定能获得焦点。
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索应用", text: $query)
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
                    AppListRow(app: app, isOn: Binding(
                        get: { selected.contains(app.bundleID) },
                        set: { on in
                            if on { selected.insert(app.bundleID) }
                            else { selected.remove(app.bundleID) }
                            // 触发排序动画
                            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {}
                        }
                    ))
                }
            }
            .padding(8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(.spring(duration: 0.35, bounce: 0.15), value: selected)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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
            AppListSection(footnote: footnote, selected: $selected, apps: apps)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}
