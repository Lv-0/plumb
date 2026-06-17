import SwiftUI

/// 设置列表的单个应用行：图标 + 名称 + Toggle。
/// 按设计图：[图标] 名称 ………… [开关]
struct AppListRow: View {
    let app: InstalledAppInfo
    @Binding var isOn: Bool
    @State private var iconScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(path: app.path)
                .scaleEffect(iconScale)
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
        .onChange(of: isOn) { _, _ in
            // 弹性反馈：放大后回弹。
            withAnimation(.spring(duration: 0.3, bounce: 0.4)) { iconScale = 1.18 }
            withAnimation(.spring(duration: 0.3)) { iconScale = 1.0 }
        }
    }
}
