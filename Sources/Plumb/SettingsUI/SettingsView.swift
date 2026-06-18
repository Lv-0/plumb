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
// 设计说明：玻璃材质由外层 NSGlassEffectView 提供，本视图内容透明叠加；标签/卡片再
// 各自用 .glassEffect 局部增强质感。
// ─────────────────────────────────────────────────────────────────────────────

/// 设置根视图：顶部标签栏（居中/平铺/权限）+ 下方内容区。
/// 采用上下布局，左右对称；窗口整体背景由 NSGlassEffectView 提供 Liquid Glass 材质，
/// SwiftUI 内容透明叠加其上，因此窗口边缘也呈现玻璃质感。
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
        // 上下对称布局：顶部居中标签 + 中部内容，左右等距留白。
        VStack(spacing: 0) {
            tabBar
            Divider()
                .opacity(0.25)
            detailContainer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 显式 Liquid Glass 背景：整窗呈现可感知的磨砂玻璃材质，
        // 而非几乎透明地直接透出桌面。
        .background(
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(Color.primary.opacity(0.001))  // 非空填充触发 glassEffect 作用域
                .glassEffect(.regular, in: Rectangle())
                .ignoresSafeArea()
        )
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
            // 背景层：选中=强调色，未选中=Liquid Glass。仅作用于背景，不拦截点击。
            // 用 .regular（非 interactive）：interactive 玻璃可能参与命中测试与 Button 竞争，
            // 导致标签点击不灵敏。静态玻璃即可。
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear))
                .glassEffect(.regular,
                             in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .animation(.spring(duration: 0.32, bounce: 0.18), value: isSelected)
    }
}
