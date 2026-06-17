# Liquid Glass Redesign + Multi-Screen Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重构设置界面为 SwiftUI + Liquid Glass（macOS 26），修复多屏选屏 bug（中心点归属），并润色窗口居中/平铺动画。

**Architecture:** UI 层（SwiftUI 重写）与引擎层（AppKit/AX 保留）解耦。多屏选屏逻辑提取为不依赖 `NSScreen` 的纯函数（`ScreenSelection` / `WindowGeometry`），使其可单测。SwiftUI 视图承载设置交互；`WindowCenteringService` / `WindowAnimator` 保留并做针对性修复。

**Tech Stack:** Swift 6.2, SwiftUI（macOS 26, `.glassEffect()` / `NavigationSplitView`）, AppKit (`NSWindow`, `NSHostingController`, `AXUIElement`), swift-testing。

**Spec:** `docs/superpowers/specs/2026-06-16-liquid-glass-redesign-design.md`

---

## 文件结构

### 新建
- `Sources/centerWindows/ScreenSelection.swift` —— **纯函数**多屏选屏（不依赖 NSScreen）。`screenIndexByCenter(center:in:)` + `insetsFromVisibleFrame(frame:visible:)`。无 AppKit 依赖。
- `Sources/centerWindows/SettingsUI/SettingsView.swift` —— SwiftUI 根视图（`NavigationSplitView`）。
- `Sources/centerWindows/SettingsUI/AppListSection.swift` —— 应用列表段（图标+名称+Toggle）。
- `Sources/centerWindows/SettingsUI/AppListRow.swift` —— 单行（图标 + 名称 + Toggle + 弹性反馈）。
- `Sources/centerWindows/SettingsUI/AppIconView.swift` —— `InstalledAppInfo.path` → `NSWorkspace.shared.icon` → SwiftUI `Image`。
- `Sources/centerWindows/SettingsUI/PermissionsSection.swift` —— 权限状态行 + 两个 recessed 按钮。
- `Sources/centerWindows/SettingsUI/TilingSection.swift` —— 平铺应用列表 + 边距滑块。
- `Tests/centerWindowsTests/ScreenSelectionTests.swift` —— 多屏选屏纯函数测试。

### 修改
- `Package.swift:7` —— `.macOS(.v13)` → `.macOS(.v26)`。
- `Sources/centerWindows/SettingsWindowController.swift` —— 全文替换为瘦身版（`NSHostingController` 承载 `SettingsView`）。删除 `AppPickerView` 引用、旧 AppKit UI。
- `Sources/centerWindows/WindowCenteringService.swift` —— `detectWindowContext` 选屏改为“中心点归属”优先（调用 `ScreenSelection`）；`effectiveVisibleFrame` 改用提取出的纯函数。
- `Sources/centerWindows/AppDelegate.swift:52-59` —— `openSettings` 创建窗口部分沿用，窗口参数适配。
- `Sources/centerWindows/WindowGeometry.swift` —— 新增 `insetsFromVisibleFrame(frame:visible:)` 静态方法（把 `effectiveVisibleFrame` 的逐屏 inset 计算下沉为可测纯函数）。

### 删除
- `Sources/centerWindows/AppPickerView.swift` —— 被 SwiftUI `AppListSection` 取代。

### 不变
- `WindowGeometry.centeredOrigin` / `tiledFrame` / `constrainedOrigin` —— 几何定义正确，不动。
- `WindowAnimator` —— 主参数保留；仅 Task 12 加可选 spring 变体。
- `InstalledAppCatalog` —— 已返回 `.path`，支持图标。
- `AppTilingSettings` / `AppTilingSettingsStore` —— 持久化模型不变。

---

## 任务依赖与执行顺序

```
Task 1 (平台提升) ──┐
Task 2 (纯函数提取)──┤
                   ├──> Task 3 (多屏修复) ──> Task 4 (多屏测试)
                   │
Task 5-9 (SwiftUI UI, 阶段 A 排版) ──> Task 10 (壳窗口接入)
                                       │
Task 11 (UI 动画, 阶段 B) <────────────┘
Task 12 (窗口动效润色)
Task 13 (全量验证)
```

Task 1/2 可并行。Task 3 依赖 2。Task 4 依赖 3。Task 5-9 互相独立但构成 UI 主体，建议顺序。Task 10 依赖 5-9。Task 11 依赖 10。Task 12 独立。Task 13 最后。

---

## Task 1: 提升平台到 macOS 26

**Files:**
- Modify: `Package.swift:7`

- [ ] **Step 1: 修改 platforms**

把 `Package.swift` 第 7 行：
```swift
        .macOS(.v13)
```
改为：
```swift
        .macOS(.v26)
```

- [ ] **Step 2: 验证编译**

Run: `swift build 2>&1 | tail -20`
Expected: 编译成功（可能有 deprecation 警告，但无 error）。现有代码在 macOS 26 SDK 下应可编译。

- [ ] **Step 3: 验证测试仍绿**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with 16 tests passed`

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "chore: raise deployment target to macOS 26 for Liquid Glass"
```

---

## Task 2: 提取纯函数多屏选屏逻辑（TDD）

**Files:**
- Create: `Sources/centerWindows/ScreenSelection.swift`
- Create: `Tests/centerWindowsTests/ScreenSelectionTests.swift`

**为什么先做这个**：`WindowCenteringService.detectWindowContext` 的选屏是 `private`，无法单测。先把纯几何逻辑（不含 `NSScreen`）提取出来，才能 TDD 多屏修复。测试目标不导入 AppKit。

- [ ] **Step 1: 写失败测试**

创建 `Tests/centerWindowsTests/ScreenSelectionTests.swift`：
```swift
import CoreGraphics
import Testing
@testable import centerWindows

@Test
func selectByCenterWhenCenterInsideOneScreen() {
    // 主屏 [0,0,1440,900]，副屏 [1440,0,1920,1080]
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    // 窗口中心在副屏内
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 2000, y: 500), inScreens: screens)
    #expect(idx == 1)
}

@Test
func selectByCenterPrefersPrimaryWhenCenterInPrimary() {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 720, y: 450), inScreens: screens)
    #expect(idx == 0)
}

@Test
func selectByCenterFallsBackToMaxOverlapWhenCenterOnSeam() {
    // 两屏在 x=1440 接缝，中心恰在接缝上（不严格 contained）
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 1440, y: 450), inScreens: screens)
    // 缝隙回退最大重叠：中心点对两屏都是边界，应返回 0（首个命中 / 稳定默认）
    #expect(idx == 0)
}

@Test
func selectByCenterSingleScreen() {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 100, y: 100), inScreens: screens)
    #expect(idx == 0)
}

@Test
func selectByCenterEmptyScreensReturnsNil() {
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 100, y: 100), inScreens: [])
    #expect(idx == nil)
}

@Test
func insetsFromVisibleFrameComputesPerEdgeInsets() {
    // frame = 全屏 [0,0,1440,900]；visibleFrame 因底部 Dock(75) + 顶部菜单栏(25) 缩小
    let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 75, width: 1440, height: 800)
    let insets = WindowGeometry.insetsFromVisibleFrame(frame: frame, visible: visible)
    #expect(insets.left == 0)
    #expect(insets.right == 0)
    #expect(insets.bottom == 75)
    #expect(insets.top == 25)
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ScreenSelection 2>&1 | tail -10`
Expected: FAIL —— `ScreenSelection` 未定义，`WindowGeometry.insetsFromVisibleFrame` 不存在。

- [ ] **Step 3: 实现 ScreenSelection**

创建 `Sources/centerWindows/ScreenSelection.swift`：
```swift
import CoreGraphics

/// 纯函数多屏选屏：不依赖 AppKit/NSScreen，便于单测。
/// “app 原先在哪屏就在哪屏居中/平铺” —— 用窗口中心点归属选屏。
enum ScreenSelection {
    struct EdgeInsets: Equatable {
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    /// 返回中心点所属屏幕的下标。
    /// - 优先：中心被某屏 `contains`（严格内部，含边界）。
    /// - 回退：中心恰在缝隙/外部时，返回最大重叠面积的屏幕；都不重叠返回 nil。
    static func screenIndex(forCenter center: CGPoint, inScreens screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }

        // 唯一归属：严格 contains。
        for (i, frame) in screens.enumerated() where frame.contains(center) {
            return i
        }

        // 边界命中（contains 对边界点为 true，这里处理 contains 都未命中的极端缝隙情况）：
        // 用 1×1 的代表矩形取最大重叠，稳定返回首个最大者。
        let dot = CGRect(x: center.x, y: center.y, width: 1, height: 1)
        var best: (index: Int, area: CGFloat)?
        for (i, frame) in screens.enumerated() {
            let area = dot.intersection(frame).area2
            if let b = best {
                if area > b.area { best = (i, area) }
            } else {
                best = (i, area)
            }
        }
        return best?.index
    }
}

private extension CGRect {
    var area2: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
```

- [ ] **Step 4: 实现 WindowGeometry.insetsFromVisibleFrame**

在 `Sources/centerWindows/WindowGeometry.swift` 的 `enum WindowGeometry { ... }` 内（`tiledFrame` 之后）添加：
```swift
    /// 把“全屏 frame 与可用 visibleFrame”之间的逐边 inset 计算下沉为纯函数。
    /// 让 Dock 在左/右/下、菜单栏在顶部的逐屏差异可被独立测试。
    static func insetsFromVisibleFrame(frame: CGRect, visible: CGRect) -> ScreenSelection.EdgeInsets {
        ScreenSelection.EdgeInsets(
            left: visible.minX - frame.minX,
            right: frame.maxX - visible.maxX,
            top: frame.maxY - visible.maxY,
            bottom: visible.minY - frame.minY
        )
    }
```

- [ ] **Step 5: 运行测试确认通过**

Run: `swift test --filter ScreenSelection 2>&1 | tail -10`
Expected: 全部 6 个测试 PASS。

- [ ] **Step 6: Commit**

```bash
git add Sources/centerWindows/ScreenSelection.swift Sources/centerWindows/WindowGeometry.swift Tests/centerWindowsTests/ScreenSelectionTests.swift
git commit -m "feat: extract pure-function screen selection (center-point ownership)"
```

---

## Task 3: 应用中心点归属选屏到 WindowCenteringService

**Files:**
- Modify: `Sources/centerWindows/WindowCenteringService.swift`（`detectWindowContext` ~`:740`、`effectiveVisibleFrame` ~`:1132`）

**背景**：当前选屏在 `detectWindowContext` 内按“最大重叠面积 + 距离 + 缓存 bonus”选，可能把跨边界窗口归到错误屏 → 居中目标按错误屏的 `visibleFrame` 计算 → 窗口跳屏。改为：先用中心点归属确定屏幕，再用该屏逐空间评分选 `RawSpace`。

- [ ] **Step 1: 修改 detectWindowContext 加入中心点归属优先**

把 `detectWindowContext`（约 `:740-786`）整体替换为：
```swift
    private func detectWindowContext(rawPosition: CGPoint, windowSize: CGSize, pid: pid_t?, primaryTopY: CGFloat) -> WindowContext? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let cachedScreen: NSScreen? = {
            guard let pid, let id = cachedDisplayByPID[pid] else { return nil }
            return screens.first(where: { displayID(for: $0) == id })
        }()
        let cachedSpace: RawSpace? = {
            guard let pid else { return nil }
            return cachedSpaceByPID[pid]
        }()

        // 收集每个 (screen, space) 的全局 rect + 中心点。
        struct Entry {
            let screen: NSScreen
            let space: RawSpace
            let globalRect: CGRect
            let overlap: CGFloat
            let distance2: CGFloat
        }
        var entries: [Entry] = []
        for screen in screens {
            let screenFrame = screen.frame
            for space in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] {
                let globalRect = rawToGlobalRect(space: space, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
                let overlap = globalRect.intersection(screenFrame).area
                let dist2 = distanceSquaredFromRectCenter(globalRect, to: screenFrame)
                entries.append(Entry(screen: screen, space: space, globalRect: globalRect, overlap: overlap, distance2: dist2))
            }
        }

        // === 中心点归属优先 ===
        // 对每个 space 的全局 rect 取中心，用 ScreenSelection（纯函数）决定它属于哪屏。
        // 命中一致的屏幕即锁定。这是“app 原先在哪屏就在哪屏”的核心。
        var centerHitScreen: NSScreen?
        var centerHitEntries: [Entry] = []
        for space in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] {
            let same = entries.filter { $0.space == space }
            let centers = same.map { CGPoint(x: $0.globalRect.midX, y: $0.globalRect.midY) }
            let frames = screens.map { $0.frame }
            // 任一 space 的中心能唯一归属即采纳（取首个命中的 space，通常 globalBottomLeft 优先）。
            for (i, entry) in same.enumerated() {
                guard let idx = ScreenSelection.screenIndex(forCenter: centers[i], inScreens: frames) else { continue }
                if entry.screen === screens[idx] {
                    centerHitScreen = entry.screen
                    centerHitEntries = same
                    break
                }
            }
            if centerHitScreen != nil { break }
        }

        // 在锁定的屏幕上选最优 space（用既有 consider 评分）。
        func pickBest(_ pool: [Entry]) -> Entry? {
            var best: Entry?
            for e in pool {
                guard var b = best else { best = e; continue }
                var dummy: ContextCandidate?
                consider(candidate: ContextCandidate(screen: e.screen, space: e.space, globalRect: e.globalRect, overlap: e.overlap, distance2: e.distance2),
                         best: &dummy, cachedScreen: cachedScreen, cachedSpace: cachedSpace)
                // consider 写回 dummy；这里只用 overlap 主键比较（与 consider 一致）。
                let candOverlap = (cachedScreen === e.screen && cachedSpace == e.space) ? e.overlap + 0.25 : e.overlap
                let bestOverlap = (cachedScreen === b.screen && cachedSpace == b.space) ? b.overlap + 0.25 : b.overlap
                if candOverlap > bestOverlap + 0.5 { best = e }
                _ = b
                b = best!
                _ = b
            }
            return best
        }

        let chosen: Entry?
        if let centerHitScreen, !centerHitEntries.isEmpty {
            let pool = centerHitEntries.filter { $0.screen === centerHitScreen }
            chosen = pickBest(pool)
        } else {
            // 回退：全量评分（保留旧行为作为兜底）。
            chosen = pickBest(entries)
        }

        guard let chosen else { return nil }

        // 更新缓存：有意义的重叠才视为可靠。
        if let pid, chosen.overlap > 1 {
            if let id = displayID(for: chosen.screen) { cachedDisplayByPID[pid] = id }
            cachedSpaceByPID[pid] = chosen.space
            return WindowContext(screen: chosen.screen, space: chosen.space, overlap: chosen.overlap, currentGlobalRect: chosen.globalRect)
        }

        // 重叠不足：若有缓存屏，用缓存屏 + 缓存 space 保守返回。
        if let cachedScreen, let cachedSpace {
            let screenFrame = cachedScreen.frame
            let globalRect = rawToGlobalRect(space: cachedSpace, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
            return WindowContext(screen: cachedScreen, space: cachedSpace, overlap: 0, currentGlobalRect: globalRect)
        }
        return WindowContext(screen: chosen.screen, space: chosen.space, overlap: chosen.overlap, currentGlobalRect: chosen.globalRect)
    }
```

> **注意**：上述 `pickBest` 内联简化了评分（直接用 overlap 比较），避免 `consider` 的 inout 写法在闭包里别扭。若编译器对 `consider` 调用报 unused 警告，移除该行即可——核心比较已由 `candOverlap/bestOverlap` 完成。

- [ ] **Step 2: effectiveVisibleFrame 改用纯函数**

把 `effectiveVisibleFrame`（约 `:1132-1147`）替换为：
```swift
    private func effectiveVisibleFrame(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let insets = WindowGeometry.insetsFromVisibleFrame(frame: frame, visible: visible)
        return CGRect(
            x: frame.minX + insets.left,
            y: frame.minY + insets.bottom,
            width: frame.width - insets.left - insets.right,
            height: frame.height - insets.top - insets.bottom
        )
    }
```

- [ ] **Step 3: 验证编译**

Run: `swift build 2>&1 | tail -20`
Expected: 编译成功。若 `pickBest` 内 `consider` 调用产生警告，按注释移除该行（核心比较已在内联）。

- [ ] **Step 4: 验证现有测试仍绿（回归）**

Run: `swift test 2>&1 | tail -5`
Expected: 全部通过（含 Task 2 新增的 6 个 ScreenSelection 测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/centerWindows/WindowCenteringService.swift
git commit -m "fix: select screen by window-center ownership (multi-monitor no longer jumps)"
```

---

## Task 4: 多屏选屏边界测试加固

**Files:**
- Modify: `Tests/centerWindowsTests/ScreenSelectionTests.swift`

**目的**：覆盖 spec 的“跨边界窗口”“缓存粘性被覆盖”“双屏不同 Dock”场景（纯函数层面）。

- [ ] **Step 1: 追加测试**

在 `ScreenSelectionTests.swift` 末尾追加：
```swift
@Test
func crossBoundaryWindowCenterStaysOnOriginalScreen() {
    // 主屏 [0,0,1440,900]，副屏 [1440,0,1920,1080]
    // 窗口跨边界但中心明显在副屏（x=1700）→ 必须归属副屏，不跳主屏。
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 1700, y: 540), inScreens: screens)
    #expect(idx == 1)
}

@Test
func cachedScreenIsOverriddenWhenCenterMovesToOtherScreen() {
    // 即便“上次在主屏”（调用方缓存），只要中心点现在落在副屏，归属副屏。
    // ScreenSelection 是无状态的，直接验证：中心在副屏 → 返回副屏。
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 2500, y: 500), inScreens: screens)
    #expect(idx == 1)
}

@Test
func differentDockPositionsDoNotAffectScreenOwnership() {
    // 两屏的“可见区”差异不影响选屏（选屏只用 frame，逐屏 inset 在 effectiveVisibleFrame 处理）。
    // 这里验证 ScreenSelection 只看 frame。
    let screens = [CGRect(x: -1920, y: 0, width: 1920, height: 1080),  // 左侧副屏
                   CGRect(x: 0, y: 0, width: 1440, height: 900)]       // 主屏
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: -1000, y: 500), inScreens: screens)
    #expect(idx == 0)
}
```

- [ ] **Step 2: 运行测试**

Run: `swift test --filter ScreenSelection 2>&1 | tail -10`
Expected: 全部 9 个 ScreenSelection 测试 PASS。

- [ ] **Step 3: Commit**

```bash
git add Tests/centerWindowsTests/ScreenSelectionTests.swift
git commit -m "test: cover cross-boundary, cache-override, asymmetric multi-screen cases"
```

---

## Task 5: AppIconView（应用图标组件）

**Files:**
- Create: `Sources/centerWindows/SettingsUI/AppIconView.swift`

> **UI subagent 阶段 A 起点**：本任务及 Task 6-9 属于“UI 界面排版设计”，先做结构、不做动画（动画在 Task 11）。

- [ ] **Step 1: 实现 AppIconView**

创建 `Sources/centerWindows/SettingsUI/AppIconView.swift`：
```swift
import AppKit
import SwiftUI

/// 应用图标：InstalledAppInfo.path → NSWorkspace.shared.icon(forFile:) → SwiftUI Image。
/// 24×24，圆角 5（与设计图一致）。
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

- [ ] **Step 2: 验证编译**

Run: `swift build 2>&1 | tail -10`
Expected: 编译成功。

- [ ] **Step 3: Commit**

```bash
git add Sources/centerWindows/SettingsUI/AppIconView.swift
git commit -m "feat(ui): add AppIconView (NSWorkspace icon → SwiftUI Image)"
```

---

## Task 6: AppListRow（单行：图标+名称+Toggle）

**Files:**
- Create: `Sources/centerWindows/SettingsUI/AppListRow.swift`

- [ ] **Step 1: 实现 AppListRow（阶段 A：仅结构，无动画）**

创建 `Sources/centerWindows/SettingsUI/AppListRow.swift`：
```swift
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
```

- [ ] **Step 2: 验证编译**

Run: `swift build 2>&1 | tail -10`
Expected: 编译成功。

- [ ] **Step 3: Commit**

```bash
git add Sources/centerWindows/SettingsUI/AppListRow.swift
git commit -m "feat(ui): add AppListRow (icon + name + toggle, no animation yet)"
```

---

## Task 7: AppListSection（应用列表段，居中/平铺共用）

**Files:**
- Create: `Sources/centerWindows/SettingsUI/AppListSection.swift`

- [ ] **Step 1: 实现 AppListSection**

创建 `Sources/centerWindows/SettingsUI/AppListSection.swift`：
```swift
import SwiftUI

/// 居中/平铺段共用的“应用列表”：每应用一行 Toggle，绑定到 settings 的某个 Set<String>。
/// 按设计图：无总开关、无搜索框；顶部一行脚注说明“空列表 = 全部居中”的隐含语义。
struct AppListSection<Root>: View where Root: AnyObject {
    let footnote: String
    @Binding var settings: Root
    let keyPath: ReferenceWritableKeyPath<Root, Set<String>>
    let apps: [InstalledAppInfo]

    var body: some View {
        List {
            Section {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(apps, id: \.bundleID) { app in
                    AppListRow(app: app, isOn: Binding(
                        get: { settings[keyPath: keyPath].contains(app.bundleID) },
                        set: { on in
                            if on { settings[keyPath: keyPath].insert(app.bundleID) }
                            else { settings[keyPath: keyPath].remove(app.bundleID) }
                        }
                    ))
                    .listRowBackground(Color.clear)
                }
            }
        }
    }
}
```

> **注意**：`AppTilingSettings` 是 `struct` 不是 `class`，故用值类型绑定更自然。修正见 Step 2。

- [ ] **Step 2: 改为值类型绑定（AppTilingSettings 是 struct）**

把 `AppListSection.swift` 整体替换为：
```swift
import SwiftUI

/// 居中/平铺段共用的“应用列表”：每应用一行 Toggle，绑定到 settings 的某个 Set<String>。
/// 按设计图：无总开关、无搜索框；顶部脚注说明“空列表 = 全部居中”的隐含语义。
struct AppListSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]

    var body: some View {
        List {
            Section {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(apps, id: \.bundleID) { app in
                    AppListRow(app: app, isOn: Binding(
                        get: { selected.contains(app.bundleID) },
                        set: { on in
                            if on { selected.insert(app.bundleID) }
                            else { selected.remove(app.bundleID) }
                        }
                    ))
                    .listRowBackground(Color.clear)
                }
            }
        }
    }
}
```

- [ ] **Step 3: 验证编译**

Run: `swift build 2>&1 | tail -10`
Expected: 编译成功。

- [ ] **Step 4: Commit**

```bash
git add Sources/centerWindows/SettingsUI/AppListSection.swift
git commit -m "feat(ui): add AppListSection (value-type binding, footnote + app rows)"
```

---

## Task 8: TilingSection 与 PermissionsSection

**Files:**
- Create: `Sources/centerWindows/SettingsUI/TilingSection.swift`
- Create: `Sources/centerWindows/SettingsUI/PermissionsSection.swift`

- [ ] **Step 1: 实现 TilingSection（应用列表 + 边距滑块）**

创建 `Sources/centerWindows/SettingsUI/TilingSection.swift`：
```swift
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
```

- [ ] **Step 2: 实现 PermissionsSection**

创建 `Sources/centerWindows/SettingsUI/PermissionsSection.swift`：
```swift
import SwiftUI

/// 权限段：状态行 + 两个 recessed 按钮。
struct PermissionsSection: View {
    @State private var accessibilityOK = false
    @State private var screenCaptureOK = false

    var body: some View {
        Form {
            Section("辅助功能 / 屏幕录制") {
                Text(statusText)
                    .foregroundStyle(.secondary)

                Button("打开辅助功能设置…") {
                    AccessibilityPermission.openSettings()
                    refresh()
                }
                Button("打开屏幕录制设置…") {
                    ScreenCapturePermission.openSettings()
                    refresh()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private var statusText: String {
        "辅助功能：\(accessibilityOK ? "已授权 ✓" : "未授权")    屏幕录制：\(screenCaptureOK ? "已授权 ✓" : "未授权")"
    }

    private func refresh() {
        accessibilityOK = AccessibilityPermission.ensureTrusted(prompt: false)
        screenCaptureOK = ScreenCapturePermission.ensureAuthorized(prompt: false)
    }
}
```

- [ ] **Step 3: 验证编译**

Run: `swift build 2>&1 | tail -10`
Expected: 编译成功。

- [ ] **Step 4: Commit**

```bash
git add Sources/centerWindows/SettingsUI/TilingSection.swift Sources/centerWindows/SettingsUI/PermissionsSection.swift
git commit -m "feat(ui): add TilingSection (margin slider + list) and PermissionsSection"
```

---

## Task 9: SettingsView（根视图，NavigationSplitView）

**Files:**
- Create: `Sources/centerWindows/SettingsUI/SettingsView.swift`

- [ ] **Step 1: 实现 SettingsView**

创建 `Sources/centerWindows/SettingsUI/SettingsView.swift`：
```swift
import SwiftUI

/// 设置根视图：三段侧边栏（居中/平铺/权限）+ 内容区。
/// 按设计图：无“通用”段。侧边栏由 NavigationSplitView 自动渲染 Liquid Glass。
struct SettingsView: View {
    let store: AppTilingSettingsStore
    @State private var settings: AppTilingSettings
    @State private var section: Section = .centering
    @State private var apps: [InstalledAppInfo] = []

    enum Section: Hashable, CaseIterable {
        case centering, tiling, permissions
        var title: String {
            switch self {
            case .centering: return "居中"
            case .tiling: return "平铺"
            case .permissions: return "权限"
            }
        }
        var symbol: String {
            switch self {
            case .centering: return "scope"
            case .tiling: return "square.grid.2x2"
            case .permissions: return "checkmark.shield"
            }
        }
    }

    init(store: AppTilingSettingsStore) {
        self.store = store
        _settings = State(initialValue: store.load())
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases, id: \.self) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .listStyle(.sidebar)
        } detail: {
            detailView
                .id(section)   // 切段时强制重建 → 触发过渡动画（Task 11）
        }
        .task {
            apps = await Task.detached(priority: .userInitiated) {
                InstalledAppCatalog.loadInstalledApps()
            }.value
        }
        .onChange(of: settings) { _, new in
            store.save(new)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch section {
        case .centering:
            AppListSection(
                footnote: "空列表 = 居中所有应用；打开开关即仅居中所选应用。",
                selected: $settings.centeredBundleIDs,
                apps: apps
            )
        case .tiling:
            TilingSection(settings: $settings, apps: apps)
        case .permissions:
            PermissionsSection()
        }
    }
}
```

- [ ] **Step 2: 验证编译**

Run: `swift build 2>&1 | tail -10`
Expected: 编译成功。

- [ ] **Step 3: Commit**

```bash
git add Sources/centerWindows/SettingsUI/SettingsView.swift
git commit -m "feat(ui): add SettingsView (3-section NavigationSplitView, Liquid Glass)"
```

---

## Task 10: 重写 SettingsWindowController（瘦身壳）

**Files:**
- Modify: `Sources/centerWindows/SettingsWindowController.swift`（全文替换）
- Delete: `Sources/centerWindows/AppPickerView.swift`

- [ ] **Step 1: 重写 SettingsWindowController**

把 `Sources/centerWindows/SettingsWindowController.swift` 全文替换为：
```swift
import AppKit
import SwiftUI

/// 瘦身后的设置窗口壳：只负责 NSWindow 与 NSHostingController 承载 SwiftUI 内容。
/// Liquid Glass 由 SwiftUI 视图自身 + 窗口透明材质实现。
@MainActor
final class SettingsWindowController: NSWindowController {

    private let store: AppTilingSettingsStore

    init(store: AppTilingSettingsStore) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 760, height: 520)
        window.isOpaque = false
        window.center()

        let hosting = NSHostingController(rootView: SettingsView(store: store))
        window.contentViewController = hosting

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        // 出现动画：弹簧缩放 + 淡入（Task 11 会用更顺滑的 spring）。
        window?.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            window?.animator().alphaValue = 1
        })
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 2: 删除 AppPickerView**

```bash
git rm Sources/centerWindows/AppPickerView.swift
```

- [ ] **Step 3: 验证编译**

Run: `swift build 2>&1 | tail -15`
Expected: 编译成功。若 AppDelegate 引用了已删除的类型，确认无残留（AppDelegate 只用 `SettingsWindowController(store:)`，不涉及 AppPickerView）。

- [ ] **Step 4: 验证测试**

Run: `swift test 2>&1 | tail -5`
Expected: 全部通过（测试不涉及 UI）。

- [ ] **Step 5: Commit**

```bash
git add Sources/centerWindows/SettingsWindowController.swift
git commit -m "refactor(ui): rewrite SettingsWindowController as SwiftUI host; remove AppPickerView"
```

---

## Task 11: UI 动画与微交互（阶段 B）

**Files:**
- Modify: `Sources/centerWindows/SettingsUI/SettingsView.swift`
- Modify: `Sources/centerWindows/SettingsUI/AppListRow.swift`
- Modify: `Sources/centerWindows/SettingsUI/AppIconView.swift`
- Modify: `Sources/centerWindows/SettingsWindowController.swift`

> **UI subagent 阶段 B**：阶段 A 已完成排版，本任务加动画。

- [ ] **Step 1: 分段切换过渡动画**

在 `SettingsView.swift` 的 `detail` 闭包内，给 `detailView` 加过渡：
```swift
        } detail: {
            detailView
                .id(section)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.spring(duration: 0.35, bounce: 0.1), value: section)
        }
```

- [ ] **Step 2: AppListRow 加 Toggle 弹性反馈**

在 `AppListRow.swift` 增加 `@State private var iconScale` 与 `onChange`：
```swift
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
```

- [ ] **Step 3: 应用列表加载渐入**

在 `AppListSection.swift` 的 `ForEach` 内，给每行加出现过渡：
```swift
                    AppListRow(app: app, isOn: Binding(
                        get: { selected.contains(app.bundleID) },
                        set: { on in
                            if on { selected.insert(app.bundleID) }
                            else { selected.remove(app.bundleID) }
                        }
                    ))
                    .listRowBackground(Color.clear)
                    .transition(.opacity)
```
并在 `SettingsView.body` 的 `List` 层加 `.animation(.smooth, value: apps.count)`。

- [ ] **Step 4: 窗口出现用 spring**

在 `SettingsWindowController.showWindow` 内，把淡入改为缩放+淡入：
```swift
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.alphaValue = 0
        let f = window?.frame ?? .zero
        let scaled = NSRect(origin: f.origin, size: NSSize(width: f.width * 0.96, height: f.height * 0.96))
        window?.setFrame(scaled, display: true, animate: false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().alphaValue = 1
            window?.animator().setFrame(f, display: true)
        })
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 5: 验证编译**

Run: `swift build 2>&1 | tail -10`
Expected: 编译成功。

- [ ] **Step 6: Commit**

```bash
git add Sources/centerWindows/SettingsUI/ Sources/centerWindows/SettingsWindowController.swift
git commit -m "feat(ui): add section transition, toggle spring, list fade-in, window spring"
```

---

## Task 12: 窗口居中/平铺动画润色（spring 变体）

**Files:**
- Modify: `Sources/centerWindows/WindowAnimator.swift`
- Modify: `Tests/centerWindowsTests/WindowAnimatorTests.swift`

- [ ] **Step 1: 写失败测试**

在 `WindowAnimatorTests.swift` 末尾追加：
```swift
@Test
func springInterpolationEndpoints() {
    #expect(WindowAnimator.spring(0) == 0)
    #expect(WindowAnimator.spring(1) == 1)
}

@Test
func springMonotonicInRange() {
    var prev: CGFloat = -1
    for i in 0...30 {
        let v = WindowAnimator.spring(CGFloat(i) / 30.0)
        #expect(v >= 0 && v <= 1.0001)
        #expect(v >= prev || abs(v - prev) < 0.001)
        prev = v
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter springInterpolation 2>&1 | tail -8`
Expected: FAIL —— `WindowAnimator.spring` 不存在。

- [ ] **Step 3: 实现 spring**

在 `WindowAnimator.swift` 的 `easeInOut` 之后添加：
```swift
    /// 阻尼弹簧近似（用于手动“立即居中”的更顺滑手感；自动触发仍用 easeInOut）。
    /// 单调、过冲很小，t∈[0,1] → [0,1]。
    static func spring(_ t: CGFloat) -> CGFloat {
        let clamped = Swift.max(0, Swift.min(1, t))
        // 临界阻尼弹簧的近似：1 - (1 + 2t) * e^(-2t)
        let e = exp(-2 * Double(clamped))
        let v = 1 - (1 + 2 * Double(clamped)) * e
        return CGFloat(v)
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter spring 2>&1 | tail -8`
Expected: 两个 spring 测试 PASS。

- [ ] **Step 5: 在 centerFrontmostWindow 启用 spring（手动触发）**

在 `WindowCenteringService.centerWindowElementAnimated`（约 `:227`）的 `WindowAnimator.animate(...)` 调用处，把插值替换为 spring。由于 `animate` 内部固定用 `interpolatedRect`/`easeInOut`，最简单的方式是新增 `animate` 的 `easing` 参数。把 `animate` 签名扩展：

在 `WindowAnimator.swift` 的 `animate` 方法上增加 `easing: @escaping (CGFloat) -> CGFloat = easeInOut` 参数，把 `interpolatedRect(from:to:t:)` 调用替换为用 `easing`：
```swift
    static func animate(
        from startFrame: CGRect,
        to endFrame: CGRect,
        duration: TimeInterval = defaultDuration,
        easing: (CGFloat) -> CGFloat = easeInOut,
        writer: @escaping FrameWriter,
        reader: @escaping CurrentReader,
        completion: Completion? = nil
    ) {
        // ... 内部把
        //   let frame = interpolatedRect(from: startFrame, to: endFrame, t: progress).rounded()
        // 改为：
        //   let p = easing(progress)
        //   let frame = CGRect(
        //       x: (startFrame.minX + (endFrame.minX - startFrame.minX) * p).rounded(),
        //       y: (startFrame.minY + (endFrame.minY - startFrame.minY) * p).rounded(),
        //       width: (startFrame.width + (endFrame.width - startFrame.width) * p).rounded(),
        //       height: (startFrame.height + (endFrame.height - startFrame.height) * p).rounded()
        //   )
        // 完整实现见 Step 6。
```

- [ ] **Step 6: 完整替换 animate 方法**

把 `WindowAnimator.swift` 中整个 `animate(from:to:duration:writer:reader:completion:)` 方法替换为：
```swift
    static func animate(
        from startFrame: CGRect,
        to endFrame: CGRect,
        duration: TimeInterval = defaultDuration,
        easing: (CGFloat) -> CGFloat = easeInOut,
        writer: @escaping FrameWriter,
        reader: @escaping CurrentReader,
        completion: Completion? = nil
    ) {
        guard duration > 0 else {
            _ = writer(endFrame)
            completion?()
            return
        }

        let intervalNanos: Int = 1_000_000_000 / tickHz
        let tickCount = sampleCount(duration: duration)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(intervalNanos))

        var index = 0
        var lastWritten: CGRect? = startFrame
        var finished = false

        timer.setEventHandler {
            if index >= tickCount {
                if !finished {
                    finished = true
                    _ = writer(endFrame)
                    lastWritten = endFrame
                    timer.cancel()
                    completion?()
                }
                return
            }

            let progress = CGFloat(index) / CGFloat(tickCount)
            index += 1

            let p = easing(progress)
            let frame = CGRect(
                x: (startFrame.minX + (endFrame.minX - startFrame.minX) * p).rounded(),
                y: (startFrame.minY + (endFrame.minY - startFrame.minY) * p).rounded(),
                width: (startFrame.width + (endFrame.width - startFrame.width) * p).rounded(),
                height: (startFrame.height + (endFrame.height - startFrame.height) * p).rounded()
            )

            if let lastWritten, let current = reader() {
                let dx = abs(current.midX - lastWritten.midX)
                let dy = abs(current.midY - lastWritten.midY)
                if dx > jumpAbortThreshold || dy > jumpAbortThreshold {
                    if !finished {
                        finished = true
                        timer.cancel()
                        DiagnosticLog.debug("animator: aborted (user moved window dx=\(dx) dy=\(dy))")
                        completion?()
                    }
                    return
                }
            }

            if writer(frame) {
                lastWritten = frame
            }
        }

        timer.resume()
    }
```

- [ ] **Step 7: 手动居中调用点传 spring**

在 `WindowCenteringService.centerWindowElementAnimated`（约 `:227`）的 `WindowAnimator.animate(...)` 调用，加 `easing: WindowAnimator.spring`：
```swift
        WindowAnimator.animate(
            from: CGRect(origin: startOrigin, size: windowSize),
            to: CGRect(origin: endOrigin, size: windowSize),
            easing: WindowAnimator.spring,
            writer: { [weak self] frame in
                // ... 保持不变
```

- [ ] **Step 8: 验证编译 + 全测试**

Run: `swift test 2>&1 | tail -5`
Expected: 全部通过（含新 spring 测试；既有 easeInOut 测试因 `interpolatedRect` 仍存在而不受影响）。

- [ ] **Step 9: Commit**

```bash
git add Sources/centerWindows/WindowAnimator.swift Sources/centerWindows/WindowCenteringService.swift Tests/centerWindowsTests/WindowAnimatorTests.swift
git commit -m "feat: add spring easing for manual centering (smoother feel)"
```

---

## Task 13: 全量验证与构建

**Files:** 无修改

- [ ] **Step 1: 全量测试**

Run: `swift test 2>&1 | tail -8`
Expected: 所有测试通过（原 16 + ScreenSelection 9 + spring 2 = 27 个）。

- [ ] **Step 2: Release 构建**

Run: `swift build -c release 2>&1 | tail -10`
Expected: 编译成功。

- [ ] **Step 3: 构建可运行 .app**

Run: `bash scripts/build_app.sh 2>&1 | tail -15`
Expected: 生成 `dist/centerWindows.app`。

- [ ] **Step 4: 手动验证清单（需人工）**

打开 `dist/centerWindows.app`，逐项核对：
1. 设置窗口：三段侧边栏（居中/平铺/权限），无“通用”段。
2. 居中/平铺页：每应用一行（图标+名称+开关），无搜索框、无总开关。
3. 切换侧边栏分段：内容区平滑过渡（淡入+上移）。
4. Toggle 开关：图标轻微弹性反馈。
5. 平铺页：顶部有边距滑块（0–400px）。
6. 权限页：状态行 + 两个按钮。
7. Liquid Glass：侧边栏与卡片有折射/模糊材质（macOS 26 下）。
8. **多屏**：把窗口拖到副屏，触发居中 → 窗口留在副屏、不跳主屏；副屏 Dock 位置不同时边距正确。
9. **平铺**：在副屏触发平铺 → 单窗口近铺满副屏、留边距、菜单栏/Dock 可见。

- [ ] **Step 5: 最终 Commit（如有残留改动）**

```bash
git add -A
git commit -m "chore: final verification pass for Liquid Glass redesign" || echo "nothing to commit"
```

---

## Self-Review 结论

**Spec 覆盖**：
- 需求 1（液态玻璃+动画）→ Task 1, 5-11。
- 需求 2（UI subagent）→ Task 5-9（阶段 A 排版）+ Task 11（阶段 B 动画），执行时由 subagent-driven-development 分派。
- 需求 3（平铺修复）→ Task 3（选屏修复后近铺满正确，不改 `tiledFrame`）。
- 需求 4（多屏）→ Task 2-4（中心点归属 + 纯函数 + 测试）。

**Placeholder 扫描**：无 TBD/TODO；每个代码步骤都有完整实现。

**类型一致性**：`ScreenSelection.screenIndex(forCenter:inScreens:)`、`WindowGeometry.insetsFromVisibleFrame(frame:visible:)`、`WindowAnimator.spring(_:)`、`WindowAnimator.animate(...,easing:)` 在定义与调用点签名一致。`AppListSection` 用值类型 `@Binding var selected: Set<String>`（与 `AppTilingSettings` 是 struct 一致）。

**风险提示**：Task 3 的 `detectWindowContext` 重写较大，建议该任务由人工 review 或 subagent-driven-development 的两阶段 review 把关。
