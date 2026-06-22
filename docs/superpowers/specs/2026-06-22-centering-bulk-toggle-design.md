# 居中标签页「全部打开 / 全部关闭」按钮 — 设计文档

- 日期：2026-06-22
- 状态：已与用户确认，待实现
- 目标：在设置窗口「居中」标签页的应用列表上方新增「全部打开」「全部关闭」两个批量操作按钮，一键勾选/取消当前可见应用。

## 1. 背景与目标

Plumb 的「居中」标签页用 `CenteringSection → AppListSection` 渲染一张带搜索框的应用列表，每行一个
`PillToggle` 决定该应用是否被加入居中白名单 `centeredBundleIDs`。当用户想批量勾选/取消多个应用时，
只能逐行点击，体验繁琐。

本次新增「全部打开 / 全部关闭」两个按钮，让用户能一键操作当前可见列表。

**成功标准（验收）：**

1. 「居中」标签页 footnote 下方、搜索框上方存在「全部打开」「全部关闭」两个按钮。
2. 「全部打开」→ 当前可见（未被搜索过滤掉）的应用全部加入 `centeredBundleIDs`。
3. 「全部关闭」→ 当前可见应用全部从 `centeredBundleIDs` 移除。
4. 列表为空或搜索无结果时，两个按钮置灰不可点。
5. 「平铺」白名单页与「文档类 App」页**不**出现这两个按钮（行为不变）。
6. 批量操作后列表重排复用现有动画。
7. 五种语言（en/zh/ja/es/fr）文案齐全（由既有 `LocalizationTests` 完整性测试保证）。

## 2. 关键语义：反转逻辑（务必理解）

居中段的语义是**反转**的（来自 `AppTilingSettings.shouldCenter` 与现有 footnote）：

- `centeredBundleIDs` **为空** → 居中**所有**应用
- `centeredBundleIDs` **非空** → 仅居中**所选**应用

因此两个按钮字面含义与实际效果是：

| 按钮 | 字面操作 | 对居中行为的实际效果 |
|------|----------|----------------------|
| 全部打开 | 把可见应用全部加入集合 | 收窄为「仅居中这些应用」 |
| 全部关闭 | 把可见应用全部移出集合 | 退回「居中所有应用」 |

**按钮行为本身不变**（只是增删集合元素）。现有 footnote（"空列表 = 居中所有应用；打开开关即仅居中
所选应用"）已说明此反转语义，用户能理解。**不额外加提示文案**，避免啰嗦。

## 3. 架构：给共享组件加可选开关

`AppListSection` 是居中/平铺/文档三处复用的共享组件。为避免污染其他两处，给它新增一个可选参数：

```swift
struct AppListSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]
    var isRowDisabled: ((InstalledAppInfo) -> Bool)? = nil
    /// 是否显示「全部打开 / 全部关闭」批量操作行。默认 false，仅居中段传 true。
    var showsBulkActions: Bool = false
    ...
}
```

`CenteringSection` 传入 `showsBulkActions: true`；`TilingSection`（白名单页）与
`DocumentChooserSection` 不传，保持原样。这是最小侵入改动，零行为回归风险。

## 4. 按钮行为

两个按钮都作用于**当前可见集合**（即 `sortedFilteredApps`，叠加搜索过滤 + 选中在前排序后的结果），
而非全量 `apps`：

- **全部打开**：`selected.formUnion(sortedFilteredApps.map(\.bundleID))`
  - 例：搜索 "office" 后点「全部打开」只勾选 office 相关应用，符合直觉，避免误操作。
- **全部关闭**：`sortedFilteredApps.map(\.bundleID).forEach { selected.remove($0) }`
  - 只移除当前可见的勾选，不动其它（被搜索过滤掉的）已选项。

**可见集合复用已有的 `sortedFilteredApps` 计算属性，零新逻辑。**

### 禁用态

- 当 `sortedFilteredApps.isEmpty`（列表为空或搜索无结果）时，两个按钮置灰（`.disabled(true)`）。
- 不做「全部已选则禁用全部打开」这类细粒度判断——重复点击无副作用，保持简单。

### 动画

复用现有的 `.animation(.spring(duration: 0.35, bounce: 0.15), value: selected)`，
批量勾选/取消时列表重排（选中项前置）自动平滑过渡。按钮动作体里包一层
`withAnimation(.spring(duration: 0.35, bounce: 0.15)) {}`（与单行 toggle 一致）触发重排动画。

## 5. UI 布局

在 `AppListSection.contentView` 的 `footnote` 与搜索框之间插入一条工具行（仅当
`showsBulkActions == true` 时渲染）：

```
┌─ 居中标签页（ScrollView 内）──────────────────┐
│ 空列表 = 居中所有应用；打开开关即仅居中所选应用。│  ← footnote
│                                                │
│ [全部打开]  [全部关闭]                          │  ← 新增工具行（居中段独有）
│ ┌──────────────────────────────────────────┐  │
│ │ 🔍 搜索应用                               │  │  ← 现有搜索框
│ └──────────────────────────────────────────┘  │
│ ┌──────────────────────────────────────────┐  │
│ │ ○  App Store                              │  │  ← 应用列表
│ │ ●  Safari                                 │  │
│ └──────────────────────────────────────────┘  │
└────────────────────────────────────────────────┘
```

**按钮样式**：复用项目既有视觉语言——`.buttonStyle(.plain)` + 极淡半透明胶囊背景
（`RoundedRectangle(cornerRadius: 9)` + `Color.primary.opacity(0.06)`），与 `SubTabPill` 的**未选中态**
视觉一致，保证与整个设置窗口的 Liquid Glass 视觉统一（不叠 `.glassEffect`，避免磨砂糊状）。
字号 12、字重 `.medium`。按钮无选中态（一次性动作），故固定用 `.medium`（不像 `SubTabPill` 那样
按选中态切换 `.semibold`/`.medium`）。

布局用 `HStack(spacing: 8)` 放两个按钮，左侧对齐；不占满宽度，与 footnote/搜索框的 leading 对齐
保持视觉节奏。

## 6. 本地化：`Localization.swift` 新增 2 个 key × 5 语言

现有 `LocalizationTests` 强制「每个 key 在所有语言表中存在」（完整性测试），故新增 key 必须五种
语言齐全。采用国际通用的 "Select All / Deselect All" 措辞（而非字面 "Open/Close"），更准确且与
"开关" 语义一致：

| Key | en | zh | ja | es | fr |
|-----|----|----|----|----|-----|
| `bulkSelectAll` | Select All | 全部打开 | すべて選択 | Seleccionar todo | Tout sélectionner |
| `bulkDeselectAll` | Deselect All | 全部关闭 | すべて解除 | Deseleccionar todo | Tout désélectionner |

需同步在三处添加（与现有 key 完全一致的代码结构）：
1. `L10n.Key` 枚举（新增 `case bulkSelectAll` / `case bulkDeselectAll`，归入"居中段"分组注释下）。
2. `table`（五种语言各加两条）。
3. 无参访问器（`static var bulkSelectAll: String { tr(.bulkSelectAll) }` 等）。

## 7. 行为与不变量

- **作用域**：批量操作只影响**当前 `sortedFilteredApps`** 对应的 bundleID；被搜索过滤掉的应用的
  勾选状态不受影响。
- **集合语义不变**：按钮只是对 `selected`（`Set<String>`）做并集/差集，不引入新的持久化字段、
  不改 `AppTilingSettings` 结构、不改 `shouldCenter` 逻辑。
- **持久化**：`selected` 是 `@Binding`，改动经 `SettingsView` 的 `onChange(of: settings)` 自动落盘
  （与单行 toggle 走完全相同的路径），无需额外保存逻辑。
- **bundleID 归一化**：列表里的 `app.bundleID` 已是 `InstalledAppCatalog` 扫描得到的原始值；
  `AppTilingSettings` 的归一化（小写）在 save 时统一处理，按钮直接用原始 ID 即可，与单行 toggle 一致。
- **可逆**：操作完全可逆（"全部关闭"→"全部打开"即恢复），无需确认弹窗。

## 8. 测试策略

- **`LocalizationTests`（既有，自动覆盖）**：已强制每个 key 在五种语言齐全。新增 2 个 key 后，若任何
  语言缺失该测试即失败 —— 无需新建测试即可覆盖文案完整性。
- **`AppListSectionTests`（既有）**：`AppListFilter.filterAndSort` 不变，现有测试零回归。
- **批量逻辑可测性**：批量操作是 SwiftUI 视图内的集合运算（`formUnion` / `remove`），属于 UI 行为
  而非可独立单测的纯函数，故不新增针对它的单测；其正确性由"复用 `sortedFilteredApps`、操作同一
  `@Binding` 集合"保证，与单行 toggle 的可测性等级一致。
- **手动集成验证（写入 spec，交付前执行）**：
  1. `scripts/build_app.sh` 产出 `dist/Plumb.app`，启动。
  2. 打开设置 → 居中标签页，确认 footnote 下方出现「全部打开」「全部关闭」。
  3. 点「全部打开」→ 列表所有应用开关变亮、置顶；确认 `~/Library/Application Support/Plumb/settings.json`
     的 `centeredBundleIDs` 含全部应用。
  4. 搜索 "safari" → 点「全部关闭」→ 仅 Safari 被取消，其它保持。
  5. 搜索一个不存在的词 → 两按钮置灰不可点。
  6. 切到「平铺」「文档类 App」页，确认**无**这两个按钮。

## 9. 范围之外（YAGNI）

- ❌ 不加「反选」按钮。
- ❌ 不加确认弹窗（操作可逆）。
- ❌ 不做"全部已选则禁用全部打开"的细粒度禁用判断。
- ❌ 不把按钮加到平铺/文档页（本次仅居中段）。
- ❌ 不改 `AppListFilter` 纯函数、不改 `AppTilingSettings` 结构。
- ❌ 不持久化"上次选择"。

## 10. 涉及文件清单

| 文件 | 改动 |
|------|------|
| `Sources/Plumb/SettingsUI/AppListSection.swift` | **修改** —— `AppListSection` 新增 `showsBulkActions` 参数；`contentView` 在 footnote 下条件渲染工具行；新增两个按钮的 action（`formUnion` / `remove`）。`CenteringSection` 传 `showsBulkActions: true`。 |
| `Sources/Plumb/Localization.swift` | **修改** —— 新增 `bulkSelectAll`、`bulkDeselectAll` 两个 key × 5 语言 + 访问器。 |
| `Tests/PlumbTests/LocalizationTests.swift` | 无需改 —— 既有完整性测试自动覆盖新 key。 |
| `Tests/PlumbTests/AppListSectionTests.swift` | 无需改 —— `AppListFilter` 不变。 |

## 11. 风险

- **共享组件污染**：`AppListSection` 被三处复用。已用默认值 `showsBulkActions: false` 隔离，
  平铺/文档页不传该参数即保持原行为，回归风险为零。
- **作用域误判**：用户可能预期「全部打开 = 勾选全部应用」而非"当前可见"。已通过仅作用于
  `sortedFilteredApps` 并在搜索时自然体现（搜 "office" 后批量只影响 office）来贴合直觉；且 footnote
  始终可见，语义清晰。
- **反转语义困惑**：详见第 2 节。按钮行为本身直观，反转语义由既有 footnote 承载，无需额外文案。
