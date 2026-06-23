import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppListRowExpandable / AppMarginDrawer (SettingsUI)
//
// 模块角色：平铺应用列表中"可展开边距抽屉"的行视图。
//
// 与 AppListRow 的区别（仅平铺白名单页使用此行）：
//   - 点击图标/名称区 → 展开/收起抽屉（AppListRow 是切换开关）。
//   - 开关由右侧 PillToggle 独立承担（命中区与 AppListRow 一致）。
//   - 抽屉内含该 app 的边距滑块 + "使用默认"按钮：
//       · 拖动滑块 → 写入 perAppMargins[bundleID]；
//       · "使用默认" → 删除该 key（回退全局 edgeMargin）。
//
// 设计依据：用户希望"点击 app 出现抽屉下拉，然后可以调整该 app 的边距"。
// 抽屉内显示当前是否为默认边距（badge），让回退语义可见。
// ─────────────────────────────────────────────────────────────────────────────

/// 平铺应用列表的可展开行：图标+名称点击展开边距抽屉，开关由右侧药丸承担。
/// `defaultMargin`：全局默认边距（顶部滑块值），供抽屉内"使用默认"按钮回退。
/// `customMarginBinding`：get 返回 perAppMargins[bundleID]（nil=未单独设置）；
///   set nil=删除 key（回退默认）、set value=写入 key。
struct AppListRowExpandable: View {
    let app: InstalledAppInfo
    let defaultMargin: CGFloat
    @Binding var isOn: Bool
    @Binding var perAppMargins: [String: CGFloat]
    var isDisabled: Bool = false

    @State private var isExpanded: Bool = false
    @State private var isHovered: Bool = false

    /// 该 app 当前是否单独设置过边距。
    private var hasCustomMargin: Bool {
        perAppMargins[app.bundleID] != nil
    }

    /// 抽屉内显示的当前边距值（自定义 or 默认）。
    private var currentMargin: CGFloat {
        perAppMargins[app.bundleID] ?? defaultMargin
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded {
                AppMarginDrawer(
                    defaultMargin: defaultMargin,
                    currentMargin: currentMargin,
                    hasCustomMargin: hasCustomMargin,
                    onChange: { setMargin($0) },
                    onUseDefault: { setMargin(nil) }
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
                    // 自定义边距标记：单独设置过边距的 app 显示一个小圆点，提示可查看。
                    if hasCustomMargin {
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

    // MARK: - 边距写入（nil = 回退默认 = 删除 key）

    private func setMargin(_ value: CGFloat?) {
        if let value {
            perAppMargins[app.bundleID] = value
            DiagnosticLog.debug("SettingsUI: set per-app margin app=\(app.bundleID) → \(value)")
        } else {
            perAppMargins.removeValue(forKey: app.bundleID)
            DiagnosticLog.debug("SettingsUI: reset per-app margin app=\(app.bundleID) → default")
        }
    }
}

/// 边距抽屉：滑块 + 当前值 + "使用默认"按钮。
/// 仅在 AppListRowExpandable 展开时渲染。
struct AppMarginDrawer: View {
    let defaultMargin: CGFloat
    let currentMargin: CGFloat
    let hasCustomMargin: Bool
    let onChange: (CGFloat) -> Void
    let onUseDefault: () -> Void

    // 滑块的本地状态：用 currentMargin 初始化，拖动时即时回调 onChange。
    // 用 @State 持有以获得流畅拖动，onAppear 时同步外部值。
    @State private var sliderValue: CGFloat

    init(defaultMargin: CGFloat, currentMargin: CGFloat, hasCustomMargin: Bool,
         onChange: @escaping (CGFloat) -> Void, onUseDefault: @escaping () -> Void) {
        self.defaultMargin = defaultMargin
        self.currentMargin = currentMargin
        self.hasCustomMargin = hasCustomMargin
        self.onChange = onChange
        self.onUseDefault = onUseDefault
        _sliderValue = State(initialValue: currentMargin)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.15)
            HStack(spacing: 12) {
                Text(L10n.margin)
                    .foregroundStyle(.secondary)
                Slider(value: $sliderValue,
                       in: AppTilingSettings.minimumEdgeMargin...AppTilingSettings.maximumEdgeMargin,
                       onEditingChanged: { editing in
                        // 拖动过程中持续写入，保证即时反馈与松手后的最终值一致。
                        onChange(sliderValue)
                       })
                Text("\(Int(sliderValue.rounded())) px")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
                // "使用默认"按钮：未自定义时置灰（已在默认态）。
                Button(action: onUseDefault) {
                    Text(L10n.useDefaultMargin)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hasCustomMargin ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!hasCustomMargin)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // 默认态徽章：未单独设置时显示"默认"。
            if !hasCustomMargin {
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
            }
        }
        // 关键修复：当生效值（currentMargin）被外部改变——例如点击"使用默认"（删除 key → 回退
        // defaultMargin）、或顶部全局滑块改变了 defaultMargin 而本 app 处于默认态——必须把
        // 滑块的本地 @State 同步回生效值。否则 @State(initialValue:) 只在首次创建时生效，
        // 滑块位置与数值会停留在旧值，与实际生效的边距不一致。
        .onChange(of: currentMargin) { _, newValue in
            sliderValue = newValue
        }
    }
}
