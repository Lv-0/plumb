import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppListRow / PillToggle (SettingsUI)
//
// 模块角色：设置列表的单行视图与自绘药丸开关。
//
// AppListRow：图标 + 名称 + 药丸开关。点击图标/名称区或药丸均可切换；
//   用 Button（非 onTapGesture）承载，两个独立命中区不互相吞点击。
//
// PillToggle：自绘轨道+滑块的胶囊形开关，避免系统 Toggle 在 macOS 上的复选框外观。
//   开启填充强调色、滑块右滑；用 Button 承载点击，玻璃作背景层 allowsHitTesting(false)
//   排除参与命中测试（修复"开关点击不灵"）。
// ─────────────────────────────────────────────────────────────────────────────

/// 设置列表的单个应用行：图标 + 名称 + 药丸开关。
/// 药丸开关使用 Liquid Glass 材质，符合 macOS 26 设计语言。
/// 交互：点击整行（图标/名称区域）切换开关；药丸本身也可独立点击。
/// 关键：行用 Button 而非 onTapGesture，PillToggle 也用 Button，
/// 两者各自独立的命中区域不会互相吞点击。
struct AppListRow: View {
    let app: InstalledAppInfo
    @Binding var isOn: Bool
    @State private var iconScale: CGFloat = 1.0
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // 图标 + 名称：整段是一个 Button，点击切换。
            Button {
                toggleWithAnimation()
            } label: {
                HStack(spacing: 12) {
                    AppIconView(path: app.path)
                        .scaleEffect(iconScale)
                    Text(app.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 药丸开关：独立 Button，命中区域仅限药丸本身。
            PillToggle(isOn: $isOn)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onChange(of: isOn) { _, _ in
            // 图标弹一下作为反馈
            withAnimation(.spring(duration: 0.3, bounce: 0.4)) { iconScale = 1.18 }
            withAnimation(.spring(duration: 0.3)) { iconScale = 1.0 }
        }
    }

    private func toggleWithAnimation() {
        withAnimation(.spring(duration: 0.32, bounce: 0.25)) {
            isOn.toggle()
        }
    }
}

/// 药丸形（胶囊）滑动开关：自绘轨道 + 滑块，避免系统 Toggle 在 macOS 上的复选框外观。
/// 开启时轨道填充强调色，滑块滑到右侧；关闭时轨道为中性玻璃色。
/// 用 Button 承载点击，命中区域稳定，不被 glassEffect 吞掉。
struct PillToggle: View {
    @Binding var isOn: Bool

    private let trackWidth: CGFloat = 40
    private let trackHeight: CGFloat = 24
    private let knobInset: CGFloat = 2
    private var knobSize: CGFloat { trackHeight - knobInset * 2 }

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.32, bounce: 0.25)) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                Capsule(style: .continuous)
                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.12))
                // 滑块
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knobOffset)
            }
            .frame(width: trackWidth, height: trackHeight)
            .contentShape(Capsule())   // 明确命中区域=整个胶囊
        }
        .buttonStyle(.plain)
        .background(
            // 极淡半透明背景层，allowsHitTesting(false) 彻底排除参与命中测试，
            // 保证 Button 始终能接收点击（修复"开关点击不灵"问题）。
            // 不用 .glassEffect：窗口已是晶莹液态玻璃，叠 glass 会变磨砂。
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .allowsHitTesting(false)
        )
        .accessibilityLabel(Text("开关"))
        .accessibilityValue(Text(isOn ? "开" : "关"))
        .accessibilityAddTraits(.isButton)
    }

    private var knobOffset: CGFloat {
        let travel = trackWidth - knobSize - knobInset * 2
        return isOn ? travel / 2 : -travel / 2
    }
}
