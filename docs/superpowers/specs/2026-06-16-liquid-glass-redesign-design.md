# 设计规格：Liquid Glass 设置界面重构 + 多屏居中/平铺修复

**日期：** 2026-06-16
**状态：** 待用户审核

## 背景与目标

centerWindows 是一个 macOS 菜单栏工具（AppKit，最低系统 macOS 13），自动居中或平铺应用窗口。本次重构围绕用户的四项需求：

1. 设置界面 UI 实现液态玻璃（Liquid Glass）效果，增加动画与顺滑度。
2. 生成一个专门负责 UI 设计的 subagent：先排版，再动画。
3. 平铺效果不符预期（参考设计图：单窗口“近铺满”，保留菜单栏与 Dock，留细边距）。
4. 多屏问题：窗口被移到错误的屏幕；app 原先在哪屏就在哪屏居中/平铺，Dock 与分辨率差异需逐屏计算。

## 已确认的决策（来自 brainstorming 对话）

| 决策点 | 选择 |
|---|---|
| 系统版本策略 | **提升到 macOS 26（.v26）**，全面采用原生 Liquid Glass，放弃 macOS 13–15 |
| UI 技术栈 | **SwiftUI 重写**（`NavigationSplitView` + `.glassEffect()`） |
| 侧边栏结构 | **按设计图：三段** —— 居中 / 平铺 / 权限（无“通用”段） |
| 居中/平铺页交互 | **按设计图：每个应用一行** = 图标 + 名称 + Toggle；无总开关、无搜索框 |
| 平铺语义 | 单窗口“近铺满”（保留细边距，菜单栏/Dock 可见，非全屏 Space） |
| 选屏算法 | **中心点归属**（窗口中心落在哪个屏幕就归属哪个） |
| 边距 | **保留可调 edgeMargin**（0–400px，默认 16）；滑块放在“平铺”段，样式与 Liquid Glass 一致 |
| 动画范围 | 设置窗口 + 窗口居中/平铺动画 |

## 参考依据（联网查询）

- [HIG — Materials](https://developer.apple.com/design/human-interface-guidelines/materials)：Liquid Glass 是浮于内容之上的功能性材料层（控件、标签栏、侧边栏），具备折射与自适应活力。
- [WWDC25 Session 310 — Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)：AppKit 采用 Liquid Glass 的官方路径。
- [WWDC25 Session 219 — Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)：设计原则——层次、和谐、连续性。
- [AppKit Implementing Liquid Glass（Xcode 26 文档）](https://github.com/artemnovichkov/xcode-26-system-prompts/blob/main/AdditionalDocumentation/AppKit-Implementing-Liquid-Glass-Design.md)。
- macOS 26 上真正的 Liquid Glass（`NSGlassEffectView` / 折射）**受 SDK 版本门控**，需对 macOS 26 SDK 编译。当前工具链 `swiftlang-6.3.2 / arm64-apple-macosx26.0` 已满足。

## 架构

### 分层

```
┌─────────────────────────────────────────────┐
│  UI 层（SwiftUI，macOS 26 原生 Liquid Glass）│
│  SettingsView · AppListRow · PermissionView  │
└───────────────┬─────────────────────────────┘
                │ NSHostingController
┌───────────────┴─────────────────────────────┐
│  SettingsWindowController（瘦身后的壳）       │
└───────────────┬─────────────────────────────┘
                │ 读写 AppTilingSettings
┌───────────────┴─────────────────────────────┐
│  引擎层（保持 AppKit/AX，不变语言）           │
│  WindowCenteringService · WindowAnimator     │
│  WindowGeometry · InstalledAppCatalog        │
└─────────────────────────────────────────────┘
```

UI 层用 SwiftUI 重写；引擎层保持 AppKit/AX（SwiftUI 无法动画化*其他 App* 的窗口），仅做针对性修复。

### 为什么引擎层不换 SwiftUI

居中/平铺通过 Accessibility API（`AXPosition`/`AXSize`）跨进程移动别人的窗口，这必须在主线程用定时器高频写值（现有 `WindowAnimator`），SwiftUI 动画只作用于本进程视图。两者职责正交。

## 组件设计

### 1. SettingsWindowController（瘦身）

仅负责：
- 创建 `NSWindow`（隐藏标题、透明标题栏、`fullSizeContentView`、透明背景、`isOpaque=false`）。
- 用 `NSHostingController(rootView: SettingsView(store:))` 承载 SwiftUI 内容。
- `showWindow` 时的窗口出现动画（弹簧缩放 + 淡入）。
- 权限按钮的 `NSWorkspace.open` 跳转。

### 2. SettingsView（SwiftUI，核心）

```swift
struct SettingsView: View {
    let store: AppTilingSettingsStore
    @State private var settings: AppTilingSettings
    @State private var section: Section = .centering

    var body: some View {
        NavigationSplitView {
            // Liquid Glass 侧边栏（系统自动渲染）
            List(selection: $section) {
                Label("居中", systemImage: "scope").tag(Section.centering)
                Label("平铺", systemImage: "square.grid.2x2").tag(Section.tiling)
                Label("权限", systemImage: "checkmark.shield").tag(Section.permissions)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch section {
            case .centering: CenteringSection(settings: $settings)
            case .tiling:    TilingSection(settings: $settings)
            case .permissions: PermissionsSection()
            }
        }
    }
}
```

`Section` 枚举：`.centering / .tiling / .permissions`（**无 .general**）。

### 3. CenteringSection / TilingSection（应用列表）

按设计图：每个应用一行 `[图标] 名称 …… [Toggle]`。

```swift
struct AppListSection: View {
    var title: String
    @Binding var settings: AppTilingSettings
    var keyPath: ReferenceWritableKeyPath<AppTilingSettings, Set<String>>
    // 居中段传入 \.centeredBundleIDs；平铺段传入 \.tiledBundleIDs
    var apps: [InstalledAppInfo]

    var body: some View {
        List {
            // 脚注行：解释“空列表 = 全部居中”的隐含语义（无总开关时必须有）
            Section {
                Text(title == "居中" ? "空列表 = 居中所有应用；打开开关即仅居中所选应用。"
                                     : "勾选希望自动平铺的应用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(apps) { app in
                    AppListRow(app: app, isOn: Binding(
                        get: { settings[keyPath: keyPath].contains(app.bundleID) },
                        set: { on in
                            if on { settings[keyPath: keyPath].insert(app.bundleID) }
                            else { settings[keyPath: keyPath].remove(app.bundleID) }
                        }
                    ))
                }
            }
        }
        .glassEffect()            // Liquid Glass 卡片层
        .animation(.smooth, value: apps)   // 列表变化顺滑
    }
}
```

### 4. AppListRow（图标 + 名称 + Toggle）

```swift
struct AppListRow: View {
    let app: InstalledAppInfo
    @Binding var isOn: Bool
    @State private var iconScale: CGFloat = 1.0   // 阶段 B：toggle 反馈

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(path: app.path)           // 见下：NSWorkspace 图标 → Image
                .scaleEffect(iconScale)
            Text(app.name).foregroundStyle(.primary)
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
                .tint(.accentColor)
                .onChange(of: isOn) { _, _ in
                    // 阶段 B：弹性反馈
                    withAnimation(.spring(duration: 0.3, bounce: 0.4)) { iconScale = 1.15 }
                    withAnimation(.spring(duration: 0.3)) { iconScale = 1.0 }
                }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// 应用图标：InstalledAppInfo.path → NSWorkspace.shared.icon(forFile:) → Image(nsImage:)
struct AppIconView: View {
    let path: String
    var body: some View {
        let nsImage = NSWorkspace.shared.icon(forFile: path)
        Image(nsImage: nsImage)
            .resizable()
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
```

**应用图标**：`InstalledAppInfo` 已有 `.path`，用 `NSWorkspace.shared.icon(forFile: path)` 取 `NSImage`，转 SwiftUI `Image(nsImage:)`，尺寸 24×24，圆角 5。

### 5. TilingSection 的边距滑块

设计图里没有滑块，但需求确认保留可调边距。放在“平铺”段顶部一行：
```
边距  ──●──────  16 px
```
用 SwiftUI `Slider` + `Text`，`.glassEffect()` 容器，样式融入卡片。

### 6. PermissionsSection

- 状态行：“辅助功能：已授权 ✓／未授权”与“屏幕录制：同上”。
- 两个 recessed 按钮：打开辅助功能设置、打开屏幕录制设置。
- 状态在窗口出现与成为 key window 时刷新。

### 7. InstalledAppCatalog（不变）

已能返回 `path`，支持图标渲染。无需改动。

## 动画与微交互（subagent 阶段 B）

### 设置窗口
- **出现**：弹簧缩放（0.96→1.0）+ 淡入（替换现有 0.2s 线性淡入）。
- **分段切换**：`detail` 内容 `.transition(.opacity.combined(with: .move(edge: .top)))` + `.animation(.spring(duration: 0.35, bounce: 0.1))`。
- **Toggle**：`isOn` 变化时图标轻微弹性（`@State scale` + `.spring`）。
- **行 hover**：`.onHover` 注入柔和的玻璃强调高亮。
- **列表加载**：应用扫描完成后逐行 `.transition(.opacity)` 渐入（staggered，避免一闪）。

### 窗口居中/平铺动画（引擎层润色）
- 现有 `WindowAnimator`：120Hz easeInOut，0.28s。保留主参数。
- 新增可选 `.spring` 插值变体（仅手动“立即居中”用；自动触发保持 easeInOut 以避免分散注意力）。
- 平铺 Phase B（从中心向外对称生长）：确认每帧重新居中逻辑无误，调优为更自然的“展开”手感。

## 平铺行为修复（需求 3）

当前 `WindowGeometry.tiledFrame` 的“近铺满”语义本身正确（`visibleFrame.insetBy(margin)`）。观测到的“效果不符”根因是需求 4 的选屏错误 + 可能的坐标空间写回失败。本设计**不改 `tiledFrame` 的几何定义**，而是修引擎的选屏与写回可靠性。

## 多屏修复（需求 4 —— 核心）

### Bug 定位
`WindowCenteringService.detectWindowContext`（`:740`）与 `detectWindowContextUsingCG`（`:788`）按 *最大重叠面积* + *中心距离* + 缓存偏好 选屏。当窗口跨边界或缓存陈旧时，启发式可能选错 `NSScreen` → 居中/平铺目标按错误屏幕的 `visibleFrame` 计算 → 窗口跳到错误屏。

### 修复方案：中心点归属

新增选屏规则：**窗口中心点落在哪个屏幕，就归属哪个屏幕。**

难点：窗口的“全局中心”依赖已知坐标空间（`RawSpace`），而空间评分本身要逐屏试。因此**两步走**：

**步骤 1 — 先求窗口的候选全局中心（不依赖具体屏幕）。**
对每个 `RawSpace`，用“当前缓存屏或主屏”的 frame 把 raw 位置转成全局 rect，取中心。由于各屏的 `localTopLeft/localBottomLeft` 转换只用到该屏自身 frame，对“跨屏一致性”影响有限，实际用一个稳定的参照屏（缓存屏优先、否则主屏）即可得到一个用于归属判定的中心点候选。

```swift
// 用参照屏（缓存屏 ?? 主屏）求一个稳定的全局中心候选。
let refScreen = cachedScreen ?? primaryScreen
let refFrame = refScreen.frame
var centerCandidates: [RawSpace: CGPoint] = [:]
for space in allSpaces {
    let r = rawToGlobalRect(space: space, screenFrame: refFrame,
                            rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
    centerCandidates[space] = CGPoint(x: r.midX, y: r.midY)
}
```

**步骤 2 — 用中心归属选屏，再用该屏逐空间评分。**
对每个候选中心点，看哪个 `NSScreen.frame.contains(center)` → 唯一归属。

```swift
private func pickScreenByCenter(_ centerCandidates: [RawSpace: CGPoint]) -> NSScreen? {
    for (_, center) in centerCandidates {
        if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return s
        }
    }
    return nil // 回退到最大重叠
}
```

### 选屏算法调整（`consider` / 排序）

1. **首选**：窗口中心被某屏 `frame.contains` 的屏幕（步骤 2）。
2. **次选**：最大重叠面积（保留作为中心点恰在缝隙/极端跨边界时的回退）。
3. **缓存粘性**：`cachedDisplayByPID` 降级为 tie-break；当窗口中心明确在另一屏时，**覆盖**缓存。
4. 坐标空间（`RawSpace`）在已选屏上再逐空间评分选最优（与现状一致），**屏幕先选、空间后选**（解耦）。

### 边界情况
- 窗口中心恰在两屏缝隙（`contains` 都不命中）→ 回退最大重叠面积。
- 窗口完全在屏外 → 回退到缓存屏（若无可回退主屏）。
- 仅一个屏 → 直接返回该屏。

### 逐屏 Dock/分辨率

`effectiveVisibleFrame(for:)`（`:1132`）已从 `screen.visibleFrame` 推导左右上下独立 inset，因此 Dock 在左/右/下、不同分辨率的逐屏差异**已被正确处理**。修复重点是确保 *选屏正确*，让正确的 `visibleFrame` 被采用。本设计增加测试验证之。

### 验收测试（新增）

在 `Tests/centerWindowsTests/MultiScreenGeometryTests.swift`：
- **双屏不同 Dock 位置**：主屏（Dock 底部）+ 副屏（Dock 右侧），构造窗口中心在副屏内 → 断言目标在副屏、且按副屏 visibleFrame 居中。
- **跨边界窗口**：窗口中心恰在副屏 → 断言不跳主屏。
- **缓存粘性**：app 上次在主屏，这次窗口中心在副屏 → 断言归属副屏（缓存被覆盖）。

`effectiveVisibleFrame` 是 `private`，需把逐屏 inset 计算下沉为可测的纯函数（如 `WindowGeometry.insetsFromVisibleFrame(frame:visible:)`）。

## 需求 → 交付物映射（验收清单）

| 需求 | 交付物 | 验证 |
|---|---|---|
| 1 液态玻璃 UI | `SettingsView` + 子视图用 `.glassEffect()`；Package 提到 .v26 | 编译通过 + 肉眼对照设计图 |
| 1 更多动画/顺滑 | 分段切换、toggle、hover、窗口出现、居中/平铺动画润色 | 运行时肉眼 + 引擎层动画单测 |
| 2 UI subagent | 实现阶段派生 subagent：阶段 A 排版、阶段 B 动画 | 实现记录 |
| 3 平铺修复 | 选屏修好后单窗口近铺满正确 | 手动 + 平铺几何单测 |
| 4 多屏 | 中心点归属选屏 + 逐屏 inset + 多屏单测 | `MultiScreenGeometryTests` 通过 |
| 不破坏现有 | 现有 `TilingGeometryTests` / `WindowAnimatorTests` / `SettingsStoreTests` 通过 | `swift test` 全绿 |

## 风险与权衡

- **提升到 macOS 26 放弃旧系统用户**：已与用户确认接受。
- **应用列表无搜索**：应用多时找应用略慢。已与用户确认“按图”。后续如需可再加。
- **空列表 = 全部居中**的隐含语义：无总开关时靠脚注文字说明，需用户理解。
- **坐标空间探测仍复杂**：本次只改选屏策略，不重写四空间评分，控制风险面。

## 不在本期范围

- 多窗口分屏拼贴（确认为非目标）。
- 菜单栏图标/alert 的 Liquid Glass 化（动画范围确认为“设置 + 窗口动效”）。
- 应用图标的自定义渲染（用系统 `NSWorkspace` 图标即可）。
