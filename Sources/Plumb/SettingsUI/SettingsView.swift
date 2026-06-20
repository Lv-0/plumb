import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SettingsView (SettingsUI)
//
// 模块角色：设置窗口的 SwiftUI 根视图。
//
// 职责：
//   - 顶部胶囊标签栏（居中 / 平铺 / 权限）+ 切换淡入淡出的内容区。
//   - 持有 settings（绑定 AppTilingSettingsStore，onChange 自动落盘）与 apps 列表。
//   - refreshApps：后台扫描已安装应用；防抖（取消旧任务）；窗口每次显示（windowDidShow
//     通知）与 .task 首次出现都触发，保证新装应用即时可见。
//   - observeWorkspaceAppLaunches：窗口在屏时监听 app 启动，实时刷新列表。
//
// 设计说明：液态玻璃由外层 NSGlassEffectView 提供，本视图被嵌入其 contentView；
// 视图本身保持透明，让真实折射/lensing 透出。标签/卡片只用极淡半透明填充区分层级，不叠 glass。
// ─────────────────────────────────────────────────────────────────────────────

/// 设置根视图：顶部标签栏（居中/平铺/权限）+ 下方内容区。
/// 采用上下布局，左右对称；窗口的液态玻璃由外层 NSGlassEffectView 提供，本视图被嵌入
/// 它的 contentView，因此内容本身就“在玻璃里”，SwiftUI 保持透明以透出折射与边缘高光。
struct SettingsView: View {
    let store: AppTilingSettingsStore
    @State private var settings: AppTilingSettings
    @State private var section: Section = .centering
    @State private var apps: [InstalledAppInfo] = []

    /// 正在进行的应用列表刷新任务。用于防抖：连续触发（快速开关窗口、多个应用同时启动）
    /// 时取消旧任务、仅保留最新一次扫描，避免冗余的文件系统遍历叠加。
    @State private var refreshTask: Task<Void, Never>?

    /// NSWorkspace 应用启动通知的观察者 token。窗口在屏时监听，使新安装并启动的应用
    /// 实时出现在列表中；窗口关闭时移除，避免泄漏与无效回调。
    @State private var workspaceObserver: NSObjectProtocol?

    enum Section: Hashable, CaseIterable {
        case centering, tiling, permissions, about
        var title: String {
            switch self {
            case .centering: return L10n.tabCentering
            case .tiling: return L10n.tabTiling
            case .permissions: return L10n.tabPermissions
            case .about: return L10n.tabAbout
            }
        }
        var symbol: String {
            switch self {
            case .centering: return "scope"
            case .tiling: return "square.grid.2x2"
            case .permissions: return "checkmark.shield"
            case .about: return "info.circle"
            }
        }
    }

    init(store: AppTilingSettingsStore) {
        self.store = store
        _settings = State(initialValue: store.load())
    }

    var body: some View {
        // 上下对称布局：顶部居中标签 + 中部内容，左右等距留白。
        VStack(spacing: 0) {
            tabBar
            Divider()
                .opacity(0.25)
            detailContainer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 不再在此叠加 .glassEffect 背景：窗口的液态玻璃由外层 NSGlassEffectView 提供
        //（本视图被嵌入它的 contentView），SwiftUI 内容保持透明，让真实折射/边缘高光透出。
        // 此前在此再叠一层 glassEffect+tint 会把折射压成磨砂色块。
        .animation(.smooth, value: apps.count)
        .task {
            // 首次出现：加载一次应用列表，并注册 NSWorkspace 观察者。
            refreshApps()
            observeWorkspaceAppLaunches()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowNotifications.windowDidShow)) { _ in
            // 设置窗口每次显示时重新扫描：AppDelegate 缓存了控制器单例，
            // 重新打开窗口不会再触发 `.task`，因此依赖本通知驱动刷新，
            // 让"打开设置 → 安装新应用 → 关闭再打开设置"能立即看到新应用。
            refreshApps()
        }
        .onDisappear {
            // 窗口关闭时移除观察者，避免泄漏；下次 `.task` 会重新注册。
            if let token = workspaceObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(token)
                workspaceObserver = nil
            }
        }
        .onChange(of: settings) { _, new in
            store.save(new)
        }
    }

    /// 后台重新扫描已安装应用并更新 `apps`。
    /// 防抖：若已有刷新在进行中，先取消，确保同一时刻至多一个扫描任务。
    private func refreshApps() {
        refreshTask?.cancel()
        let task = Task.detached(priority: .userInitiated) {
            let loaded = InstalledAppCatalog.loadInstalledApps()
            await MainActor.run { self.apps = loaded }
        }
        refreshTask = task
    }

    /// 监听应用启动：用户在设置窗口打开期间新装并启动某 App 时，列表实时更新。
    /// 使用 NSWorkspace 的通知中心（与默认 NotificationCenter 不同），仅在窗口在屏时订阅。
    private func observeWorkspaceAppLaunches() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            // `queue: .main` 保证本闭包在主线程执行；显式断言主线程隔离以调用 @MainActor 方法。
            MainActor.assumeIsolated {
                refreshApps()
            }
        }
    }

    /// 顶部标签栏：居中排列三个胶囊标签，整体左右对称。
    private var tabBar: some View {
        HStack(spacing: 10) {
            ForEach(Section.allCases, id: \.self) { s in
                TabPill(
                    title: s.title,
                    symbol: s.symbol,
                    isSelected: section == s
                ) {
                    withAnimation(.spring(duration: 0.35, bounce: 0.12)) {
                        section = s
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)   // 居中
    }

    /// 内容区：切换时纯淡入淡出交叉，避免 move 造成的跳动。
    private var detailContainer: some View {
        detailView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(section)
            .transition(.opacity)
    }

    @ViewBuilder
    private var detailView: some View {
        switch section {
        case .centering:
            CenteringSection(
                footnote: L10n.centeringFootnote,
                selected: $settings.centeredBundleIDs,
                apps: apps
            )
        case .tiling:
            TilingSection(settings: $settings, apps: apps)
        case .permissions:
            PermissionsSection()
        case .about:
            AboutSection()
        }
    }
}

/// 顶部胶囊标签：选中态用强调色填充，未选中态用 Liquid Glass。
/// 关键：glassEffect 只作用于背景层（不包裹 Button），点击命中整个胶囊区域。
private struct TabPill: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minWidth: 88, minHeight: 32)
            .contentShape(Rectangle())   // 整个胶囊区域可点击
        }
        .buttonStyle(.plain)
        .background {
            // 背景层：选中=强调色，未选中=极淡半透明。
            // 不再用 .glassEffect：窗口本身已是晶莹液态玻璃，控件再叠一层 glass 会“玻璃上叠玻璃”
            // 变成磨砂/糊状。这里只用一层很淡的填充区分层级，让窗口的单一折射透出。
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(Color.accentColor)
                      : AnyShapeStyle(Color.primary.opacity(0.06)))
        }
        .animation(.spring(duration: 0.32, bounce: 0.18), value: isSelected)
    }
}
