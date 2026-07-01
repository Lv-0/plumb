import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppListRowExpandable / AppInsetsDrawer (SettingsUI)
//
// 模块角色：平铺应用列表中"可展开间距抽屉"的行视图。
//
// 与 AppListRow 的区别（仅平铺白名单页使用此行）：
//   - 点击图标/名称区 → 展开/收起抽屉（AppListRow 是切换开关）。
//   - 开关由右侧 PillToggle 独立承担（命中区与 AppListRow 一致）。
//   - 抽屉内含该 app 的 上/下/左/右 四个方向间距滑块 + "使用默认"按钮：
//       · 拖动任一方向滑块 → 写入 perAppInsets[bundleID] 对应字段；
//       · "使用默认" → 删除该 key（回退全局 edgeMargin 铺满 4 向）。
//
// 设计依据：用户希望"点击 app 出现抽屉下拉，然后可以分别调整该 app 的上下左右间距"。
// 抽屉内显示当前是否为默认间距（badge），让回退语义可见。
// ─────────────────────────────────────────────────────────────────────────────

/// 平铺应用列表的可展开行：图标+名称点击展开间距抽屉，开关由右侧药丸承担。
/// `defaultMargin`：全局默认间距标量（顶部滑块值），供抽屉内"使用默认"按钮回退。
/// `customInsetsBinding`：get 返回 perAppInsets[bundleID]（nil=未单独设置）；
///   set nil=删除 key（回退默认）、set value=写入 key。
struct AppListRowExpandable: View {
    let app: InstalledAppInfo
    let defaultMargin: CGFloat
    @Binding var isOn: Bool
    @Binding var perAppInsets: [String: TileInsets]
    var isDisabled: Bool = false

    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false

    /// 该 app 当前是否单独设置过间距。
    private var hasCustomInsets: Bool {
        perAppInsets[app.bundleID] != nil
    }

    /// 抽屉内显示的当前四向间距值（自定义 or 默认）。
    private var currentInsets: TileInsets {
        perAppInsets[app.bundleID] ?? TileInsets(all: defaultMargin)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded {
                AppInsetsDrawer(
                    defaultMargin: defaultMargin,
                    currentInsets: currentInsets,
                    hasCustomInsets: hasCustomInsets,
                    onChange: { setInsets($0) },
                    onUseDefault: { setInsets(nil) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered && !isDisabled ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    // MARK: - 头部行（图标 + 名称 + 展开指示 + 药丸）

    private var headerRow: some View {
        HStack(spacing: 12) {
            // 图标 + 名称：点击展开/收起抽屉（与 AppListRow 不同——此处不切换开关）。
            Button {
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                    isExpanded.toggle()
                }
                DiagnosticLog.debug("SettingsUI: expand app=\(app.bundleID) name='\(app.name)' now=\(isExpanded ? "OPEN" : "CLOSE")")
            } label: {
                HStack(spacing: 12) {
                    AppIconView(path: app.path)
                    Text(app.name)
                        .foregroundStyle(isDisabled ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // 自定义间距标记：单独设置过间距的 app 显示一个小圆点，提示可查看。
                    if hasCustomInsets {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                    Spacer(minLength: 8)
                    // 展开方向指示箭头。
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            // 药丸开关：独立 Button，命中区域仅限药丸本身（与 AppListRow 一致）。
            PillToggle(isOn: $isOn, isDisabled: isDisabled)
        }
        .opacity(isDisabled ? 0.55 : 1.0)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    // MARK: - 间距写入（nil = 回退默认 = 删除 key）

    private func setInsets(_ value: TileInsets?) {
        if let value {
            perAppInsets[app.bundleID] = value
            DiagnosticLog.debug("SettingsUI: set per-app insets app=\(app.bundleID) → \(value)")
        } else {
            perAppInsets.removeValue(forKey: app.bundleID)
            DiagnosticLog.debug("SettingsUI: reset per-app insets app=\(app.bundleID) → default")
        }
    }
}

/// 间距抽屉：上/下/左/右 各一行滑块 + 当前值 + "使用默认"按钮。
/// 仅在 AppListRowExpandable 展开时渲染。
struct AppInsetsDrawer: View {
    let defaultMargin: CGFloat
    let currentInsets: TileInsets
    let hasCustomInsets: Bool
    let onChange: (TileInsets) -> Void
    let onUseDefault: () -> Void

    // 四个方向滑块的本地状态：用 currentInsets 初始化，拖动时即时回调 onChange。
    // 用 @State 持有以获得流畅拖动，onAppear / onChange 时同步外部值。
    @State private var top: CGFloat
    @State private var bottom: CGFloat
    @State private var left: CGFloat
    @State private var right: CGFloat

    init(defaultMargin: CGFloat, currentInsets: TileInsets, hasCustomInsets: Bool,
         onChange: @escaping (TileInsets) -> Void, onUseDefault: @escaping () -> Void) {
        self.defaultMargin = defaultMargin
        self.currentInsets = currentInsets
        self.hasCustomInsets = hasCustomInsets
        self.onChange = onChange
        self.onUseDefault = onUseDefault
        _top = State(initialValue: currentInsets.top)
        _bottom = State(initialValue: currentInsets.bottom)
        _left = State(initialValue: currentInsets.left)
        _right = State(initialValue: currentInsets.right)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.15)

            VStack(spacing: 8) {
                DirectionSliderRow(label: L10n.marginTop, value: $top) { commitAll() }
                DirectionSliderRow(label: L10n.marginBottom, value: $bottom) { commitAll() }
                DirectionSliderRow(label: L10n.marginLeft, value: $left) { commitAll() }
                DirectionSliderRow(label: L10n.marginRight, value: $right) { commitAll() }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // "使用默认"按钮：未自定义时置灰（已在默认态）。
                Button(action: onUseDefault) {
                    Text(L10n.useDefaultMargin)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hasCustomInsets ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!hasCustomInsets)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // 默认态徽章：未单独设置时显示"默认"。
            if !hasCustomInsets {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text("\(L10n.perAppMarginDefaultBadge): \(Int(defaultMargin.rounded())) px")
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else {
                // 自定义态留出底部间距，保持两种状态高度一致。
                Color.clear.frame(height: 8)
            }
        }
        // 关键修复：当生效值（currentInsets）被外部改变——例如点击"使用默认"（删除 key → 回退
        // TileInsets(all: defaultMargin)）、或顶部全局滑块改变了 defaultMargin 而本 app 处于默认态
        // ——必须把四个方向的本地 @State 同步回生效值。否则 @State(initialValue:) 只在首次创建时生效，
        // 滑块位置与数值会停留在旧值，与实际生效的间距不一致。
        .onChange(of: currentInsets) { _, newValue in
            top = newValue.top
            bottom = newValue.bottom
            left = newValue.left
            right = newValue.right
        }
    }

    /// 把四个本地 @State 组装为 TileInsets 回调写入。
    private func commitAll() {
        onChange(TileInsets(top: top, bottom: bottom, left: left, right: right))
    }
}

/// 单方向滑块行：标签 + 滑块 + 数值。
private struct DirectionSliderRow: View {
    let label: String
    @Binding var value: CGFloat
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Slider(value: $value,
                   in: AppTilingSettings.minimumEdgeMargin...AppTilingSettings.maximumEdgeMargin,
                   onEditingChanged: { editing in
                       // 拖动过程中持续写入，保证即时反馈与松手后的最终值一致。
                       onCommit()
                   })
            Text("\(Int(value.rounded())) px")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }
}
