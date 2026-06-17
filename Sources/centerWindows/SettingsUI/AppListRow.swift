import SwiftUI

/// 设置列表的单个应用行：图标 + 名称 + Toggle。
/// 按设计图：[图标] 名称 ………… [开关]
struct AppListRow: View {
    let app: InstalledAppInfo
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(path: app.path)
            Text(app.name)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.accentColor)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
