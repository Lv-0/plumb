import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppListRow / PillToggle (SettingsUI)
//
// 模块角色：设置列表的单行视图与开关。
//
// AppListRow：图标 + 名称 + 开关。点击图标/名称区或开关均可切换；
//   用 Button（非 onTapGesture）承载，两个独立命中区不互相吞点击。
//
// PillToggle：自绘轨道 + 立体玻璃质感滑块。滑块用 LinearGradient(顶亮→底暗) + 顶部椭圆
//   高光 overlay + 多层 shadow 合成"玻璃球"质感——纯 SwiftUI，不依赖系统 Liquid Glass 材质
//   （.glassEffect() 与系统 Toggle 的玻璃材质在 NSGlassEffectView 窗口内都渲染近乎透明，
//   系统限制）。用 Button 承载点击，玻璃作背景层 allowsHitTesting(false) 排除参与命中测试
//   （修复"开关点击不灵"）。对外接口（isOn / isDisabled）不变，7 个调用点零改动。
// ─────────────────────────────────────────────────────────────────────────────

/// 设置列表的单个应用行：图标 + 名称 + 开关。
/// 交互：点击整行（图标/名称区域）切换开关；开关本身也可独立点击。
/// 关键：行用 Button 而非 onTapGesture，PillToggle 也用 Button，
/// 两者各自独立的命中区域不会互相吞点击。
///
/// `isDisabled`：置灰且不可切换，名称后显示提示文案。用于「文档类 App」页中
/// 未加入平铺白名单的 App——选择器感知仅在 App 被平铺时才生效，故未平铺时
/// 不允许开启，并提示用户先加入平铺列表。默认 false（向后兼容现有调用）。
struct AppListRow: View {
    let app: InstalledAppInfo
    @Binding var isOn: Bool
    var isDisabled: Bool = false
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
                        .foregroundStyle(isDisabled ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // 置灰行显示依赖提示（如「先加入平铺列表」）。
                    if isDisabled {
                        Text(L10n.documentChooserDisabledHint)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            // 药丸开关：独立 Button，命中区域仅限药丸本身。
            PillToggle(isOn: $isOn, isDisabled: isDisabled)
        }
        .opacity(isDisabled ? 0.55 : 1.0)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered && !isDisabled ? Color.accentColor.opacity(0.08) : Color.clear)
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
        guard !isDisabled else { return }
        // 记录用户操作步骤：哪个 App 被切换、开/关，便于复现「记录消失」时回溯操作链。
        let before = isOn
        DiagnosticLog.debug("SettingsUI: toggle app=\(app.bundleID) name='\(app.name)' \(before ? "ON→OFF" : "OFF→ON")")
        withAnimation(.spring(duration: 0.32, bounce: 0.25)) {
            isOn.toggle()
        }
    }
}

/// 药丸形（胶囊）滑动开关：自绘轨道 + 立体玻璃质感滑块。
///
/// 为什么不用系统材质：`.glassEffect()` modifier 与系统 Toggle(.switch) 的 Liquid Glass 材质
/// 在本窗口（NSGlassEffectView 玻璃窗口）内都渲染近乎透明/无质感（系统限制：glass 采样不到
/// glass 背后的内容，glass-on-glass 被抑制）。故改用纯 SwiftUI 合成滑块质感：
///   - 主体 Circle + LinearGradient（顶亮 → 底暗）= 球体明暗
///   - 顶部小椭圆白色高光 overlay = 镜面反光
///   - 多层 shadow = 浮起深度
/// 不依赖任何系统材质采样，在玻璃窗口里稳定可见。
///
/// 对外接口（`isOn`、`isDisabled`）与原自绘版本完全一致，7 个调用点零改动。
/// `isDisabled`：置灰且不可点击（默认 false）。用于依赖未满足时的行（如未平铺的文档类 App）。
struct PillToggle: View {
    @Binding var isOn: Bool
    var isDisabled: Bool = false

    private let trackWidth: CGFloat = 40
    private let trackHeight: CGFloat = 24
    private let knobInset: CGFloat = 2
    private var knobSize: CGFloat { trackHeight - knobInset * 2 }

    var body: some View {
        Button {
            guard !isDisabled else { return }
            withAnimation(.spring(duration: 0.32, bounce: 0.25)) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                // 轨道：开启强调色、关闭中性半透明
                Capsule(style: .continuous)
                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.12))
                // 滑块：立体玻璃质感（纯 SwiftUI 合成，见上文说明）。
                knob
                    .offset(x: knobOffset)
            }
            .frame(width: trackWidth, height: trackHeight)
            .contentShape(Capsule())   // 明确命中区域=整个胶囊
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .background(
            // 极淡半透明背景层，allowsHitTesting(false) 排除参与命中测试，
            // 保证 Button 始终能接收点击（修复"开关点击不灵"问题）。
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .allowsHitTesting(false)
        )
        .accessibilityLabel(Text(L10n.toggleSwitch))
        .accessibilityValue(Text(L10n.toggleState(isOn)))
        .accessibilityAddTraits(.isButton)
    }

    /// 立体玻璃质感滑块：球体明暗渐变 + 顶部镜面高光 + 多层投影。
    private var knob: some View {
        Circle()
            .fill(
                // 顶亮（白）→ 底暗（中灰）：较强的明暗对比，在明亮玻璃窗口上肉眼可辨的球体质感。
                // 此前用 0.82 对比太淡，与原版纯白圆几乎无差别；拉到 0.65 让玻璃感一眼可见。
                LinearGradient(
                    colors: [Color.white, Color(white: 0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                // 深色细描边：勾勒球体边缘，增强立体感与对比，是"一眼能看出质感"的关键
                Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)    // 主投影：浮起感
            .shadow(color: .black.opacity(0.08), radius: 0.5, x: 0, y: 0.5)  // 紧贴投影：边缘清晰
            .overlay(
                // 顶部小椭圆高光：镜面反光，是"玻璃球"质感的关键
                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.95), Color.white.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .frame(width: knobSize * 0.7, height: knobSize * 0.45)
                    .offset(y: -knobSize * 0.18)
            )
            .frame(width: knobSize, height: knobSize)
    }

    private var knobOffset: CGFloat {
        let travel = trackWidth - knobSize - knobInset * 2
        return isOn ? travel / 2 : -travel / 2
    }
}
