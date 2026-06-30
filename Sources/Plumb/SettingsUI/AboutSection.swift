import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AboutSection (SettingsUI)
//
// 模块角色：设置中"关于"标签页的内容视图。
//
// 职责：展示当前软件版本号（取自 AppVersion.current，即 CFBundleShortVersionString），
//   「检查更新」按钮（复用 UpdateCoordinator 的模态弹窗反馈，使隐藏菜单栏图标时也能更新），
//   「自动检查更新」开关（PillToggle，绑定 SettingsView 的 settings.autoCheckUpdates 自动落盘），
//   以及一个可点击打开 GitHub 仓库主页（https://github.com/Lv-0/plumb）的按钮。
//
// 说明：除 autoCheckUpdates 绑定外，无其它状态/持久化。版本号每次显示时实时读取（计算属性）；
//   GitHub 按钮点击即用 NSWorkspace.shared.open 在默认浏览器打开，无前置条件。
// ─────────────────────────────────────────────────────────────────────────────

/// 关于段：版本号行 + GitHub 按钮行，整体放在与权限卡片一致的 Liquid Glass 容器里。
struct AboutSection: View {
    /// 与 SettingsView 同源的设置绑定：改这里即触发其 `.onChange(of: settings) → store.save`，
    /// 避免另起数据源导致 stale 覆盖（与 PermissionsSection.hideStatusBarIcon 同模式）。
    /// 控制「自动」更新检查（启动/后台定期/打开设置）；手动检查不受此开关限。
    @Binding var autoCheckUpdates: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                aboutCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    /// 关于卡片：上半版本号行，下半 GitHub 行，用 Divider 分隔。
    /// 视觉与权限卡片一致：极淡 Color.primary.opacity(0.04) 的 RoundedRectangle 填充，不叠 glass。
    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 行 1：应用名 + 版本号
            HStack(spacing: 12) {
                Image(systemName: "drop.fill")   // 与状态栏水滴图标呼应
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.appName)          // "Plumb"（永不本地化）
                        .foregroundStyle(.primary)
                    Text("\(L10n.aboutVersion) \(AppVersion.current.formatted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }

            Divider()
                .opacity(0.25)

            // 行 2：检查更新行。与 GitHub 行对称：图标 + 标题/副标题 + 右侧按钮。
            // 复用 UpdateCoordinator.checkForUpdatesManually()：与状态栏菜单入口同一路径，
            // 反馈也走现有模态 NSAlert（已是最新/检查失败/发现新版本→下载进度窗口）。
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")   // 与状态栏「检查更新」菜单项图标一致
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.otaCheckForUpdates)
                        .foregroundStyle(.primary)
                    Text(L10n.aboutCheckUpdatesHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button(L10n.otaCheckForUpdates, action: checkForUpdates)
                    .buttonStyle(.bordered)
            }

            Divider()
                .opacity(0.25)

            // 行 3：自动检查更新开关行。与 PermissionsSection.hideStatusBarIconCard 同构：
            // 图标 + 标题/副标题 + 右侧 PillToggle。绑定 $autoCheckUpdates 即经 SettingsView 的
            // `.onChange(of: settings) → store.save` 自动落盘，无需本视图另写持久化。
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle")   // 周期性自动检查的语义图标
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.autoCheckUpdates)
                        .foregroundStyle(.primary)
                    Text(L10n.autoCheckUpdatesHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                PillToggle(isOn: $autoCheckUpdates)
                    .animation(.spring(duration: 0.32, bounce: 0.25), value: autoCheckUpdates)
            }

            Divider()
                .opacity(0.25)

            // 行 4：GitHub 按钮行
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.aboutGitHub)
                        .foregroundStyle(.primary)
                    Text(L10n.aboutGitHubHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button(L10n.aboutViewOnGitHub, action: openGitHub)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// 在默认浏览器打开 GitHub 仓库主页。
    /// URL 硬编码：与 UpdateChecker 的 appcast URL、publish_release.sh 的 GITHUB_REPOSITORY 用途不同，不抽公共常量。
    private func openGitHub() {
        if let url = URL(string: "https://github.com/Lv-0/plumb") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 触发手动检查更新。委托给 UpdateCoordinator（状态栏菜单的同一路径），
    /// 反馈走现有模态弹窗：已是最新 / 检查失败 / 发现新版本→下载进度窗口。
    /// 保留这条入口是为了让「隐藏菜单栏图标」开启后仍可在设置里更新。
    private func checkForUpdates() {
        UpdateCoordinator.shared.checkForUpdatesManually()
    }
}
