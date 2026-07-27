import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppListRowExpandable / AppInsetsDrawer (SettingsUI)
//
// 模块角色：平铺应用列表中"可展开间距抽屉"的行视图。
//
// 与 AppListRow 的区别（仅平铺白名单页使用此行）：
//   - 点击图标/名称区 → 展开/收起抽屉（AppListRow 是切换开关）。
//   - 开关由右侧 PillToggle 独立承担（命中区与 AppListRow 一致）。
//   - 抽屉内含该 app 的 上/下/左/右 四个方向间距（滑块 + 可直接输入数字）+ "使用默认"按钮：
//       · 拖动滑块或在数字框输入 → 写入 perAppInsets[bundleID] 对应字段；
//       · "使用默认" → 删除该 key（回退全局 edgeInsets）。
//
// 设计依据：用户希望"点击 app 出现抽屉下拉，然后可以分别调整该 app 的上下左右间距"。
// 抽屉内显示当前是否为默认间距（badge），让回退语义可见。
// ─────────────────────────────────────────────────────────────────────────────

/// 平铺应用列表的可展开行：图标+名称点击展开间距抽屉，开关由右侧药丸承担。
/// `defaultInsets`：全局默认四向间距（顶部卡片 edgeInsets），供抽屉内"使用默认"按钮回退。
/// `customInsetsBinding`：get 返回 perAppInsets[bundleID]（nil=未单独设置）；
///   set nil=删除 key（回退默认）、set value=写入 key。
struct AppListRowExpandable: View {
    let app: InstalledAppInfo
    let defaultInsets: TileInsets
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
        perAppInsets[app.bundleID] ?? defaultInsets
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded {
                AppInsetsDrawer(
                    defaultInsets: defaultInsets,
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

/// 间距抽屉：上/下/左/右 各一行（滑块 + 可输入数字）+ "使用默认"按钮。
/// 仅在 AppListRowExpandable 展开时渲染。
struct AppInsetsDrawer: View {
    let defaultInsets: TileInsets
    let currentInsets: TileInsets
    let hasCustomInsets: Bool
    let onChange: (TileInsets) -> Void
    let onUseDefault: () -> Void

    // 抽屉只有一份本地编辑草稿。四个方向共享同一个 TileInsets，外部默认值或
    // "使用默认"变化时整体替换，避免四个独立 @State 在 SwiftUI 更新顺序中部分滞留。
    @State private var editorState: AppInsetsEditorState
    /// 每次"使用默认"递增。正在编辑的 MarginRow 记录开始编辑时的 generation；
    /// 若失焦时 generation 已变化，说明旧编辑已被重置，必须丢弃而不能回写。
    @State private var resetGeneration: UInt64 = 0

    init(defaultInsets: TileInsets, currentInsets: TileInsets, hasCustomInsets: Bool,
         onChange: @escaping (TileInsets) -> Void, onUseDefault: @escaping () -> Void) {
        self.defaultInsets = defaultInsets
        self.currentInsets = currentInsets
        self.hasCustomInsets = hasCustomInsets
        self.onChange = onChange
        self.onUseDefault = onUseDefault
        _editorState = State(initialValue: AppInsetsEditorState(currentInsets: currentInsets))
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.15)

            VStack(spacing: 8) {
                MarginRow(
                    label: L10n.marginTop,
                    value: draftBinding(\.top),
                    editGeneration: resetGeneration
                ) { commitAll() }
                MarginRow(
                    label: L10n.marginBottom,
                    value: draftBinding(\.bottom),
                    editGeneration: resetGeneration
                ) { commitAll() }
                MarginRow(
                    label: L10n.marginLeft,
                    value: draftBinding(\.left),
                    editGeneration: resetGeneration
                ) { commitAll() }
                MarginRow(
                    label: L10n.marginRight,
                    value: draftBinding(\.right),
                    editGeneration: resetGeneration
                ) { commitAll() }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // "使用默认"按钮：未自定义时置灰（已在默认态）。
                Button {
                    // 先使所有进行中的旧编辑失效，再同步显示值，最后删除持久化 override。
                    // 无论 TextField 的失焦回调发生在按钮 action 前还是后，最终都不会复活旧值。
                    resetGeneration &+= 1
                    editorState.useDefault(defaultInsets)
                    onUseDefault()
                } label: {
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
                    Text("\(L10n.perAppMarginDefaultBadge): \(insetsSummary(defaultInsets))")
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
        // defaultInsets）、或顶部全局滑块改变了 defaultInsets 而本 app 处于默认态
        // ——必须把四个方向的本地 @State 同步回生效值。否则 @State(initialValue:) 只在首次创建时生效，
        // 滑块位置与数值会停留在旧值，与实际生效的间距不一致。
        .onChange(of: currentInsets) { _, newValue in
            editorState.synchronize(with: newValue)
        }
    }

    /// 将单一 TileInsets 草稿的某个方向暴露成 Slider/TextField 所需的 Binding。
    private func draftBinding(_ keyPath: WritableKeyPath<TileInsets, CGFloat>) -> Binding<CGFloat> {
        Binding(
            get: { editorState.draftInsets[keyPath: keyPath] },
            set: { editorState.draftInsets[keyPath: keyPath] = $0 }
        )
    }

    /// 把四个本地 @State 组装为 TileInsets 回调写入。
    private func commitAll() {
        // 默认态且草稿仍等于默认值时不创建无意义的 per-app override。
        // 这也是最后一道 stale-write 防线："使用默认"后的迟到回调只能得到 no-op。
        guard editorState.shouldCommit(
            hasCustomInsets: hasCustomInsets,
            defaultInsets: defaultInsets
        ) else { return }
        onChange(editorState.draftInsets)
    }

    /// 默认态徽章的四向数值摘要，如 "上 16 / 下 16 / 左 16 / 右 16"。
    private func insetsSummary(_ insets: TileInsets) -> String {
        "\(L10n.marginTop) \(Int(insets.top.rounded())) / \(L10n.marginBottom) \(Int(insets.bottom.rounded())) / \(L10n.marginLeft) \(Int(insets.left.rounded())) / \(L10n.marginRight) \(Int(insets.right.rounded()))"
    }
}

/// AppInsetsDrawer 的纯状态核心，隔离 SwiftUI 生命周期并允许单元测试覆盖。
struct AppInsetsEditorState: Equatable {
    var draftInsets: TileInsets

    init(currentInsets: TileInsets) {
        draftInsets = currentInsets
    }

    mutating func synchronize(with currentInsets: TileInsets) {
        draftInsets = currentInsets
    }

    mutating func useDefault(_ defaultInsets: TileInsets) {
        draftInsets = defaultInsets
    }

    func shouldCommit(hasCustomInsets: Bool, defaultInsets: TileInsets) -> Bool {
        hasCustomInsets || draftInsets != defaultInsets
    }
}

/// 输入框失焦时是否仍拥有提交权。重置发生后，旧 focus session 必须失效。
enum MarginEditCommitPolicy {
    static func canCommit(startGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        startGeneration == currentGeneration
    }
}

/// 边距数字输入的纯解析逻辑（非 @MainActor，便于单测）。
/// 把文本框字符串解析为合法边距值：trim → Double 解析（失败/空 → 0）→ 钳制到
/// `[minimumEdgeMargin, maximumEdgeMargin]` → 四舍五入到整像素。
enum MarginValueParser {
    static func parse(text: String) -> CGFloat {
        let parsed = Double(text.trimmingCharacters(in: .whitespaces)) ?? 0
        let clamped = min(max(AppTilingSettings.minimumEdgeMargin, CGFloat(parsed)),
                          AppTilingSettings.maximumEdgeMargin)
        return clamped.rounded()
    }

    static func intString(_ v: CGFloat) -> String {
        "\(Int(v.rounded()))"
    }
}

/// 单方向间距行：标签 + 滑块 + 可直接输入数字的文本框。
/// 全局顶部卡片与 per-app 抽屉共用此组件，两种输入方式（拖滑块 / 输入数字）都即时生效。
///
/// 数字输入实现要点：
///   - 用独立的 `@State textInput` 字符串绑定 TextField，避免与 CGFloat 滑块绑定互相干扰；
///   - 编辑中允许中间态（如 ""、"-"），不实时钳制；失焦/回车时再 `commit()`：解析、钳制到
///     `[minimumEdgeMargin, maximumEdgeMargin]`、回写 CGFloat 与文本框、回调 onCommit；
///   - 外部 value 变化（如滑块拖动、"使用默认"）通过 onChange 同步回文本框，保证两者一致。
struct MarginRow: View {
    let label: String
    @Binding var value: CGFloat
    var editGeneration: UInt64 = 0
    let onCommit: () -> Void

    /// TextField 的本地字符串。仅在 commit 时与 CGFloat value 双向同步。
    @State private var textInput: String = ""
    @State private var focusStartGeneration: UInt64 = 0
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Slider(value: $value,
                   in: AppTilingSettings.minimumEdgeMargin...AppTilingSettings.maximumEdgeMargin,
                   onEditingChanged: { editing in
                       // 拖动过程中持续写入（同步文本框 + 回调），保证即时反馈与松手后最终值一致。
                       textInput = MarginValueParser.intString(value)
                       onCommit()
                   })
            // 可直接输入数字的文本框：宽度紧凑、右对齐；失焦/回车时 commit（解析+钳制）。
            TextField("", text: $textInput, prompt: Text("0").foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($isTextFieldFocused)
                .frame(width: 40)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .onSubmit { commit() }
            Text("px")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)
        }
        // 外部 value 变化（滑块、使用默认、全局默认联动）→ 同步文本框。
        .onChange(of: value) { _, newValue in
            textInput = MarginValueParser.intString(newValue)
        }
        .onAppear {
            textInput = MarginValueParser.intString(value)
        }
        .onChange(of: isTextFieldFocused) { oldValue, newValue in
            if newValue {
                focusStartGeneration = editGeneration
            } else if oldValue {
                if MarginEditCommitPolicy.canCommit(
                    startGeneration: focusStartGeneration,
                    currentGeneration: editGeneration
                ) {
                    // 点击抽屉其他位置即提交，不能再依赖 onDisappear（失焦时视图通常仍挂载）。
                    commit()
                } else {
                    // "使用默认"已使这次编辑失效：恢复当前绑定值，绝不回写旧文本。
                    textInput = MarginValueParser.intString(value)
                }
            }
        }
    }

    /// 失焦/回车提交：解析文本框 → 钳制到合法范围 → 回写 value 与文本框 → 回调 onCommit。
    private func commit() {
        let resolved = MarginValueParser.parse(text: textInput)
        value = resolved
        textInput = MarginValueParser.intString(resolved)
        onCommit()
    }
}
