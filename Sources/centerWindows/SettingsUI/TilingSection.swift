import SwiftUI

/// 平铺段：顶部边距滑块（保留可调 edgeMargin）+ 应用列表。
struct TilingSection: View {
    @Binding var settings: AppTilingSettings
    let apps: [InstalledAppInfo]

    var body: some View {
        // 两个玻璃表面（滑块卡片 + 列表卡片）需要 GlassEffectContainer 才能正确混合；
        // 用 12pt 间距让它们各自悬浮，而不是 0 间距的硬分割线。
        GlassEffectContainer {
            VStack(spacing: 12) {
                // 边距滑块（设计图无，但需求确认保留可调）。
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // 滑块是交互控件，用 .interactive() 让玻璃响应 hover/press。
                .glassEffect(.regular.interactive(),
                             in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                AppListSection(
                    footnote: "勾选希望自动平铺的应用；未勾选的应用保持居中。",
                    selected: $settings.tiledBundleIDs,
                    apps: apps
                )
            }
            .padding(12)
        }
    }
}
