import SwiftUI

/// 设置根视图：三段侧边栏（居中/平铺/权限）+ 内容区。
/// 按设计图：无“通用”段。侧边栏由 NavigationSplitView 自动渲染 Liquid Glass。
struct SettingsView: View {
    let store: AppTilingSettingsStore
    @State private var settings: AppTilingSettings
    @State private var section: Section = .centering
    @State private var apps: [InstalledAppInfo] = []

    enum Section: Hashable, CaseIterable {
        case centering, tiling, permissions
        var title: String {
            switch self {
            case .centering: return "居中"
            case .tiling: return "平铺"
            case .permissions: return "权限"
            }
        }
        var symbol: String {
            switch self {
            case .centering: return "scope"
            case .tiling: return "square.grid.2x2"
            case .permissions: return "checkmark.shield"
            }
        }
    }

    init(store: AppTilingSettingsStore) {
        self.store = store
        _settings = State(initialValue: store.load())
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases, id: \.self) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .listStyle(.sidebar)
        } detail: {
            detailView
                .id(section)   // 切段时强制重建 → 触发过渡动画（Task 11）
        }
        .task {
            apps = await Task.detached(priority: .userInitiated) {
                InstalledAppCatalog.loadInstalledApps()
            }.value
        }
        .onChange(of: settings) { _, new in
            store.save(new)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch section {
        case .centering:
            AppListSection(
                footnote: "空列表 = 居中所有应用；打开开关即仅居中所选应用。",
                selected: $settings.centeredBundleIDs,
                apps: apps
            )
        case .tiling:
            TilingSection(settings: $settings, apps: apps)
        case .permissions:
            PermissionsSection()
        }
    }
}
