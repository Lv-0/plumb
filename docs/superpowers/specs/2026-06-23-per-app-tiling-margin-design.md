# Per-App Tiling Margin — Design

**Date**: 2026-06-23
**Status**: Approved (user-authorized autonomous decision)
**Goal**: 每个被平铺的 app 可单独设置平铺边距；未单独设置的 app 使用全局默认边距；在平铺应用列表中点击 app 出现抽屉下拉，调整该 app 的边距。

## 背景

当前平铺系统只有**一个全局边距** `AppTilingSettings.edgeMargin`（设置页顶部滑块），所有被平铺 app 共用。用户希望按 app 精调（例如 Slack 留宽边距、终端几乎贴边）。

关键现有数据流（来自代码探索）：

- `AppTilingSettings`（`Sources/Plumb/AppTilingSettings.swift`）：`edgeMargin: CGFloat` + `tiledBundleIDs: Set<String>`，bundle id 经 `normalizeBundleID`（trim+小写）归一化。
- `AppTilingSettingsStore`：主存储为签名无关文件 `~/Library/Application Support/Plumb/settings.json`，`UserDefaults` 镜像双写（CLAUDE.md L72）。
- `WindowEventObserver.handle`（L281–333）：`tilingSettings.edgeMargin` 注入 `tilePendingWindows` / `startTileStabilizationRetries` / `isWindowNearTiledTarget`，三者均已是 `edgeMargin: CGFloat` 参数。
- `WindowGeometry.tiledFrame(visibleFrame:edgeMargin:)`：纯函数，消费边距。
- `AppListRow`（设置列表行）：图标+名称 Button（点击切换开关）+ 右侧 `PillToggle`。
- `TilingSection` 平铺页：`AppListSection` 绑定 `tiledBundleIDs`，渲染 `AppListRow`。

## 需求拆解

1. **默认回退**：某 app 未单独设置边距 → 使用全局 `edgeMargin`（顶部滑块值）。
2. **抽屉式 UI**：平铺应用列表中点击 app → 行内抽屉下拉，含边距滑块 + "使用默认"按钮。
3. **持久化位置**：复用现有 `settings.json`（签名无关文件）+ `UserDefaults` 镜像，**不**新增存储位置。
4. **零回归**：居中页、文档类 App 页不受影响；老版本 settings 无 per-app 数据时全部走默认边距。

## 设计

### 1. 数据模型 `AppTilingSettings`

新增字段：

```swift
/// 每个 app 单独的平铺边距（key = 归一化 bundle id）。
/// key 不存在或值为 nil → 回退全局 edgeMargin。
var perAppMargins: [String: CGFloat]
```

新增解析方法（核心语义：默认回退）：

```swift
func effectiveMargin(for bundleIdentifier: String?) -> CGFloat {
    let normalized = bundleIdentifier.map(Self.normalizeBundleID) ?? ""
    if !normalized.isEmpty, let custom = perAppMargins[normalized] {
        return custom
    }
    return edgeMargin
}
```

`normalized()` 不变量扩展：对 `perAppMargins` 的每个 value 钳制到 `[minimumEdgeMargin, maximumEdgeMargin]`，key 归一化、空 value 剔除。`.default` 中 `perAppMargins = [:]`（全部走默认）。

`allListsEmpty` / `isEmptierThan`：这两个一致性守卫只统计列表条目总数（标量开关不参与）。`perAppMargins` 是"app→值"映射，其条目计数纳入两侧统计，保持守卫语义不变（文件被异常清空时 perAppMargins 也跟着空）。

### 2. 持久化 `AppTilingSettingsStore`

**文件（主存储）**：`perAppMargins` 是 `Codable` 的 `[String: CGFloat]`，自动编入 JSON，无需额外工作。

**UserDefaults（镜像）**：新增 key `tiling.perAppMargins`，存 `[String: Double]`：
- `saveToUserDefaults`：`defaults.set(Dictionary(normalized.perAppMargins.mapValues(Double.init)), forKey: Keys.perAppMargins)`。
- `loadFromUserDefaults`：向后兼容——key 缺失 → `[:]`（老版本 settings 全部走默认）；存在 → 读出并归一化。
- `load()` 一次性迁移逻辑不变：UserDefaults→文件迁移时 perAppMargins 一并写入。

向后兼容证明：旧 Plumb 版本写的 settings.json 不含 `perAppMargins` 键 → `JSONDecoder` 解码时该字段用默认值 `[:]` → 所有 app 走 `edgeMargin` 默认回退 → 行为与当前版本完全一致。

### 3. 抽屉式 UI

新增 `AppListRowExpandable`（`Sources/Plumb/SettingsUI/AppListRowExpandable.swift`），仅平铺白名单页使用：

```
┌─────────────────────────────────────────────┐
│ [icon] App Name              [pill toggle]  │  ← 点击名称区展开/收起抽屉
├─────────────────────────────────────────────┤
│ 边距  [─────●──────] 32 px  [使用默认]       │  ← 抽屉下拉（展开时）
└─────────────────────────────────────────────┘
```

- **行点击语义变更**（仅平铺页）：点击图标/名称区 → toggle `isExpanded`（抽屉动画）。**不再**切换开关——开关由右侧 `PillToggle` 独立承担（保持现有命中区设计）。
- **抽屉内容**：`Slider`（范围 `minimumEdgeMargin...maximumEdgeMargin`）+ 当前值 `px` 显示 + "使用默认"按钮。
- **绑定**：`Binding<CGFloat?>` get/set perAppMargins[bundleID]。拖动滑块 → set；"使用默认" → set nil（从字典删 key）。
- **未在白名单时**：抽屉不可展开（开关关闭的 app 没必要调边距）。
- 居中页、文档页继续用原 `AppListRow`，零回归。

`AppListSection` 增加一个可选 `perAppMargins: Binding<[String: CGFloat]>?` 参数（默认 nil → 用原 `AppListRow`；非 nil → 用 `AppListRowExpandable`）。`TilingSection` allowlist 页传入，其它调用点不传。

### 4. 边距消费点 `WindowEventObserver.handle`

L281–333 改动：

```swift
let tilingSettings = tilingSettingsStore.load()
let effectiveMargin = tilingSettings.effectiveMargin(for: frontmostApp.bundleIdentifier)
// 传 effectiveMargin 给 tilePendingWindows / startTileStabilizationRetries / isWindowNearTiledTarget
```

三处签名已是 `edgeMargin: CGFloat` 参数，仅改传入值。

## 测试计划（TDD）

1. **`AppTilingSettingsTests`**（新文件）：
   - `effectiveMargin` 回退默认（bundle 不在 map / nil）。
   - `effectiveMargin` 命中自定义（大小写/空格归一化）。
   - `normalized()` 钳制 perAppMargins 越界值 + 归一化 key。
2. **`SettingsStoreTests`**（扩展）：
   - perAppMargins 双写往返（文件 + UserDefaults）。
   - 向后兼容：无 `tiling.perAppMargins` key 时回退 `[:]`。
3. **`AppListSectionTests`**（扩展）：抽屉展开/收起的纯逻辑（如有可抽离的判定）。
4. `LocalizationTests` 已有的完整性断言会自动覆盖新增 key（5 语言表必须完整）。

## 非目标（YAGNI）

- 不做 per-app 居中边距（用户只要平铺边距）。
- 不做 per-app 四边独立边距（上下左右）——保持"uniform edge margin"既有语义。
- 不做导入/导出 per-app 配置。
- 不动 `WindowGeometry.tiledFrame` 签名（仍是单 margin 标量）。

## 风险

- **抽屉与药丸命中区冲突**：复用现有 `AppListRow` 的"Button 各自独立命中区"模式，名称区 Button 管展开、PillToggle 管开关，已验证可行。
- **JSON 兼容**：新增 optional-ish 字段需保证旧 JSON 解码不崩——Swift `Codable` 对 `[String: CGFloat]` 非可选字段在缺键时会解码失败，故需自定义 `init(from:)` 或用 `.decode` 容器的 `decodeIfPresent`。**实施时确认**。
