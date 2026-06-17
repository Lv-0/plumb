import SwiftUI

/// 平铺段：顶部边距滑块（保留可调 edgeMargin）+ 应用列表。
struct TilingSection: View {
    @Binding var settings: AppTilingSettings
    let apps: [InstalledAppInfo]

    var body: some View {
        VStack(spacing: 0) {
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

            Divider()

            AppListSection(
                footnote: "勾选希望自动平铺的应用；未勾选的应用保持居中。",
                selected: $settings.tiledBundleIDs,
                apps: apps
            )
        }
    }
}
