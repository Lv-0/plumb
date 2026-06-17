import SwiftUI

/// 设置列表的单个应用行：图标 + 名称 + 药丸开关。
/// 药丸开关使用 Liquid Glass 材质，符合 macOS 26 设计语言。
struct AppListRow: View {
    let app: InstalledAppInfo
    @Binding var isOn: Bool
    @State private var iconScale: CGFloat = 1.0
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(path: app.path)
                .scaleEffect(iconScale)
            Text(app.name)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            PillToggle(isOn: $isOn)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onChange(of: isOn) { _, _ in
            withAnimation(.spring(duration: 0.3, bounce: 0.4)) { iconScale = 1.18 }
            withAnimation(.spring(duration: 0.3)) { iconScale = 1.0 }
        }
    }
}

/// 药丸形开关：标准 iOS/macOS toggle 样式，外加 Liquid Glass 容器。
/// 开启时强调色填充，关闭时玻璃材质。
struct PillToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .tint(.accentColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: Capsule())
    }
}
