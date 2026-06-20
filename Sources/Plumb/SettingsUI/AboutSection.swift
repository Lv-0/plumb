import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AboutSection (SettingsUI)
//
// 模块角色：设置中"关于"标签页的内容视图。
//
// 职责：展示当前软件版本号（取自 AppVersion.current，即 CFBundleShortVersionString），
//   以及一个可点击打开 GitHub 仓库主页（https://github.com/Lv-0/plumb）的按钮。
//
// 说明：纯展示视图，无状态、无持久化。版本号每次显示时实时读取（计算属性）；
//   GitHub 按钮点击即用 NSWorkspace.shared.open 在默认浏览器打开，无前置条件。
// ─────────────────────────────────────────────────────────────────────────────

/// 关于段：版本号行 + GitHub 按钮行，整体放在与权限卡片一致的 Liquid Glass 容器里。
struct AboutSection: View {
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

            // 行 2：GitHub 按钮行
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
}
