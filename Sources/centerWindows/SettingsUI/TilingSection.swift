import SwiftUI

/// 平铺段：顶部边距滑块（Liquid Glass）+ 应用列表。
struct TilingSection: View {
    @Binding var settings: AppTilingSettings
    let apps: [InstalledAppInfo]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 边距滑块：Liquid Glass 容器
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text("边距")
                            .foregroundStyle(.primary)
                        Slider(value: $settings.edgeMargin,
                               in: AppTilingSettings.minimumEdgeMargin...AppTilingSettings.maximumEdgeMargin)
                        Text("\(Int(settings.edgeMargin.rounded())) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                    Text("平铺时窗口与屏幕边缘之间的间距。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                AppListSection(
                    footnote: "勾选希望自动平铺的应用；未勾选的应用保持居中。",
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
