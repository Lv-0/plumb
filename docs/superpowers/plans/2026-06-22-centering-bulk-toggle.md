# 居中标签页「全部打开 / 全部关闭」按钮 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在设置窗口「居中」标签页的应用列表上方新增「全部打开」「全部关闭」两个批量操作按钮，一键勾选/取消当前可见应用。

**Architecture:** 给共享组件 `AppListSection` 加一个可选参数 `showsBulkActions`（默认 `false`），只有 `CenteringSection` 传 `true`。按钮作用域复用现有 `sortedFilteredApps`（叠加搜索过滤后的可见列表），只对 `selected` 集合做并集/差集，不引入任何新的持久化字段或逻辑。新增 2 个本地化 key × 5 语言。

**Tech Stack:** SwiftUI (macOS 26 / Liquid Glass)、Swift 6.2、swift-testing 测试框架。

**Spec:** `docs/superpowers/specs/2026-06-22-centering-bulk-toggle-design.md`

---

## File Structure

| 文件 | 责任 | 本次改动 |
|------|------|----------|
| `Sources/Plumb/Localization.swift` | 界面文案多语言查表 | 新增 `bulkSelectAll` / `bulkDeselectAll` 两个 key × 5 语言 + 访问器 |
| `Sources/Plumb/SettingsUI/AppListSection.swift` | 居中/平铺/文档共用的应用列表组件 | `AppListSection` 新增 `showsBulkActions` 参数 + 条件渲染工具行；`CenteringSection` 传 `true` |
| `Tests/PlumbTests/LocalizationTests.swift` | 文案完整性测试 | 无需改（既有 `tableCompleteness` 自动覆盖新 key） |

**不变量：** `AppTilingSettings` 结构不变、`AppListFilter` 纯函数不变、平铺/文档页调用点不变（默认 `showsBulkActions: false`）。

---

## Task 1: 新增本地化 key（TDD —— 先让完整性测试失败）

**目的：** 加 2 个 key，让既有的 `LocalizationTests.tableCompleteness` 先失败再通过，强制五种语言齐全。

**Files:**
- Modify: `Sources/Plumb/Localization.swift`
- Test (existing, auto-coverage): `Tests/PlumbTests/LocalizationTests.swift:72` (`tableCompleteness`)

- [ ] **Step 1: 在 `L10n.Key` 枚举中新增两个 case**

打开 `Sources/Plumb/Localization.swift`，找到「居中段」分组的注释（约第 62-64 行）：

```swift
        // 居中段
        case centeringFootnote
        case searchApps
```

在其后追加两个 case（保持分组语义：批量操作属于居中段独有功能）：

```swift
        // 居中段
        case centeringFootnote
        case searchApps
        case bulkSelectAll
        case bulkDeselectAll
```

- [ ] **Step 2: 运行测试，确认失败（key 在语言表中缺失）**

Run: `swift test --filter LocalizationTests`
Expected: FAIL —— `tableCompleteness` 报 `Missing key bulkSelectAll in en`（以及 `bulkDeselectAll`）。这是预期的，因为还没在 `table` 中填值。

- [ ] **Step 3: 在 `table` 中为 5 种语言各添加两条文案**

在 `Localization.swift` 的 `.en:` 字典中，找到 `.searchApps: "Search Apps",` 这一行（约第 142 行），在其后追加：

```swift
            .searchApps: "Search Apps",
            .bulkSelectAll: "Select All",
            .bulkDeselectAll: "Deselect All",
```

在 `.es:` 字典中，找到 `.searchApps: "Buscar apps",` 这一行（约第 208 行），在其后追加：

```swift
            .searchApps: "Buscar apps",
            .bulkSelectAll: "Seleccionar todo",
            .bulkDeselectAll: "Deseleccionar todo",
```

在 `.fr:` 字典中，找到 `.searchApps: "Rechercher des apps",` 这一行（约第 274 行），在其后追加：

```swift
            .searchApps: "Rechercher des apps",
            .bulkSelectAll: "Tout sélectionner",
            .bulkDeselectAll: "Tout désélectionner",
```

在 `.zh:` 字典中，找到 `.searchApps: "搜索应用",` 这一行（约第 340 行），在其后追加：

```swift
            .searchApps: "搜索应用",
            .bulkSelectAll: "全部打开",
            .bulkDeselectAll: "全部关闭",
```

在 `.ja:` 字典中，找到 `.searchApps: "アプリを検索",` 这一行（约第 406 行），在其后追加：

```swift
            .searchApps: "アプリを検索",
            .bulkSelectAll: "すべて選択",
            .bulkDeselectAll: "すべて解除",
```

- [ ] **Step 4: 在无参访问器区新增两个访问器**

在 `Localization.swift` 的「访问器（无参）」区，找到 `static var searchApps: String { tr(.searchApps) }`（约第 475 行），在其后追加：

```swift
    static var searchApps: String { tr(.searchApps) }
    static var bulkSelectAll: String { tr(.bulkSelectAll) }
    static var bulkDeselectAll: String { tr(.bulkDeselectAll) }
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `swift test --filter LocalizationTests`
Expected: PASS —— `tableCompleteness` 不再报缺 key。

- [ ] **Step 6: 确认整体编译通过**

Run: `swift build`
Expected: BUILD SUCCEEDED（无警告、无错误）。

- [ ] **Step 7: 提交**

```bash
git add Sources/Plumb/Localization.swift
git commit -m "feat(l10n): add bulkSelectAll/bulkDeselectAll strings (5 langs)"
```

---

## Task 2: 给 `AppListSection` 加 `showsBulkActions` 参数

**目的：** 为共享组件加可选开关，默认 `false` 以保证平铺/文档页零回归。此任务仅加参数占位，下一个任务再加 UI。

**Files:**
- Modify: `Sources/Plumb/SettingsUI/AppListSection.swift:20-26`

- [ ] **Step 1: 在 `AppListSection` 结构体中新增 `showsBulkActions` 存储属性**

打开 `Sources/Plumb/SettingsUI/AppListSection.swift`，找到结构体声明（约第 20-26 行）：

```swift
struct AppListSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]
    /// 可选：判定某行是否应被置灰禁用（不可勾选 + 行内提示）。默认 nil = 全部可勾选。
    /// 用于「文档类 App」页：未加入平铺白名单的 App 置灰，因其选择器感知仅在平铺时才生效。
    var isRowDisabled: ((InstalledAppInfo) -> Bool)? = nil
```

在 `isRowDisabled` 之后追加新属性（带文档注释，说明默认值与用途，与现有注释风格一致）：

```swift
struct AppListSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]
    /// 可选：判定某行是否应被置灰禁用（不可勾选 + 行内提示）。默认 nil = 全部可勾选。
    /// 用于「文档类 App」页：未加入平铺白名单的 App 置灰，因其选择器感知仅在平铺时才生效。
    var isRowDisabled: ((InstalledAppInfo) -> Bool)? = nil
    /// 是否显示「全部打开 / 全部关闭」批量操作行。默认 false，仅居中段传 true。
    /// 平铺白名单页与文档类 App 页不传，保持原样（零回归）。
    var showsBulkActions: Bool = false
```

- [ ] **Step 2: 编译确认（参数有默认值，现有调用点无需改动）**

Run: `swift build`
Expected: BUILD SUCCEEDED —— 现有三处调用点（`CenteringSection`、`TilingSection`、`DocumentChooserSection`）均不传 `showsBulkActions`，因有默认值 `false` 而不受影响。

- [ ] **Step 3: 提交**

```bash
git add Sources/Plumb/SettingsUI/AppListSection.swift
git commit -m "feat(ui): add showsBulkActions flag to AppListSection (default false)"
```

---

## Task 3: 在 `contentView` 中渲染批量操作工具行

**目的：** 当 `showsBulkActions == true` 时，在 footnote 与搜索框之间插入一行「全部打开 / 全部关闭」按钮。按钮作用于 `sortedFilteredApps`（当前可见列表），空列表时置灰。

**Files:**
- Modify: `Sources/Plumb/SettingsUI/AppListSection.swift:50-56`（contentView 顶部）与文件末尾新增按钮子视图。

- [ ] **Step 1: 在 `contentView` 的 footnote 之后、搜索框 ZStack 之前，条件插入工具行**

打开 `Sources/Plumb/SettingsUI/AppListSection.swift`，找到 `contentView` 中 footnote 的定义（约第 51-55 行）：

```swift
        VStack(alignment: .leading, spacing: 12) {
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            // 搜索框：极淡半透明作 ZStack 底层（allowsHitTesting(false)），文本框在顶层独立
```

在 `Text(footnote)` 块之后、`// 搜索框` 注释之前，插入条件渲染的工具行：

```swift
        VStack(alignment: .leading, spacing: 12) {
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            // 批量操作行（仅居中段显示）：作用于当前搜索过滤后的可见列表。
            // 全部打开 = 并入可见 ID；全部关闭 = 移除可见 ID。空列表时两按钮置灰。
            if showsBulkActions {
                bulkActionsBar
            }

            // 搜索框：极淡半透明作 ZStack 底层（allowsHitTesting(false)），文本框在顶层独立
```

- [ ] **Step 2: 在 `AppListSection` 内新增 `bulkActionsBar` 计算属性**

仍在 `AppListSection` 结构体内（建议放在 `contentView` 计算属性之后、`body` 之后的位置，即原文件约第 121 行 `}` 之前），新增：

```swift
    /// 批量操作行：「全部打开 / 全部关闭」两个胶囊按钮，作用于当前可见列表。
    /// 视觉与 SubTabPill 未选中态一致（极淡半透明胶囊），保持 Liquid Glass 语言统一。
    /// 按钮无选中态（一次性动作），固定用 .medium 字重。
    private var bulkActionsBar: some View {
        let visibleEmpty = sortedFilteredApps.isEmpty
        return HStack(spacing: 8) {
            BulkActionButton(title: L10n.bulkSelectAll) {
                let ids = sortedFilteredApps.map(\.bundleID)
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    selected.formUnion(ids)
                }
            }
            .disabled(visibleEmpty)

            BulkActionButton(title: L10n.bulkDeselectAll) {
                let ids = Set(sortedFilteredApps.map(\.bundleID))
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    selected.subtract(ids)
                }
            }
            .disabled(visibleEmpty)

            Spacer(minLength: 0)
        }
    }
```

- [ ] **Step 3: 在文件末尾新增 `BulkActionButton` 私有子视图**

在 `Sources/Plumb/SettingsUI/AppListSection.swift` 文件最末尾（`CenteringSection` 结构体之后）追加：

```swift
// ─────────────────────────────────────────────────────────────────────────────
// MARK: - BulkActionButton
//
// 批量操作胶囊按钮：视觉与 SubTabPill 未选中态一致（极淡半透明填充 + .medium 字重），
// 不叠 .glassEffect（窗口已是液态玻璃，叠 glass 会变磨砂）。一次性动作，无选中态。
// ─────────────────────────────────────────────────────────────────────────────

private struct BulkActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }
}
```

- [ ] **Step 4: 编译确认**

Run: `swift build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 提交**

```bash
git add Sources/Plumb/SettingsUI/AppListSection.swift
git commit -m "feat(ui): render bulk select/deselect bar in AppListSection"
```

---

## Task 4: `CenteringSection` 启用批量操作

**目的：** 让居中段传 `showsBulkActions: true`，使按钮真正显示出来。

**Files:**
- Modify: `Sources/Plumb/SettingsUI/AppListSection.swift`（`CenteringSection` 结构体，约第 163-175 行）

- [ ] **Step 1: 在 `CenteringSection.body` 的 `AppListSection(...)` 初始化中传入 `showsBulkActions: true`**

找到 `CenteringSection` 结构体（文件末尾）：

```swift
struct CenteringSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]

    var body: some View {
        ScrollView {
            AppListSection(footnote: footnote, selected: $selected, apps: apps)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}
```

把 `AppListSection(...)` 初始化改为传入 `showsBulkActions: true`：

```swift
struct CenteringSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]

    var body: some View {
        ScrollView {
            AppListSection(
                footnote: footnote,
                selected: $selected,
                apps: apps,
                showsBulkActions: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}
```

- [ ] **Step 2: 编译确认**

Run: `swift build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: 运行全量测试，确认无回归**

Run: `swift test`
Expected: 全部 PASS —— `LocalizationTests`、`AppListSectionTests`（验证 `AppListFilter` 不变）、其余测试均不受影响。

- [ ] **Step 4: 提交**

```bash
git add Sources/Plumb/SettingsUI/AppListSection.swift
git commit -m "feat(ui): show bulk select/deselect buttons in centering tab"
```

---

## Task 5: 全量验证 + 手动集成确认清单

**目的：** 跑完整测试套件并构建 `.app`，按 spec 第 8 节的清单做手动验证。

**Files:** 无代码改动。

- [ ] **Step 1: 全量编译 + 测试**

Run: `swift build && swift test`
Expected: BUILD SUCCEEDED；全部测试 PASS。

- [ ] **Step 2: 构建 .app**

Run: `scripts/build_app.sh`
Expected: 产出 `dist/Plumb.app`，无错误。

- [ ] **Step 3: 手动集成验证（按 spec 第 8 节清单）**

启动 `dist/Plumb.app`，打开设置 → 居中标签页，逐项确认：

1. footnote 下方、搜索框上方出现「全部打开」「全部关闭」两个胶囊按钮。
2. 点「全部打开」→ 列表所有应用开关变亮（选中态强调色）、置顶重排。
3. 点「全部关闭」→ 所有应用开关变暗、列表恢复字母序。
4. 搜索 "safari"（或任意存在的词）→ 点「全部关闭」→ 仅匹配项被取消勾选，其它保持。
5. 搜索一个不存在的词（如 "zzz"）→ 两按钮置灰不可点。
6. 切到「平铺」标签页 → 子标签「平铺应用列表」「文档类 App」两页**均无**这两个按钮。
7. 切到「权限」「关于」标签页 → 无异常。

- [ ] **Step 4: 若全部通过，提交收尾（如有遗留改动）**

```bash
git status   # 确认工作区干净（本次应无新增改动，仅用于确认）
```

Expected: `nothing to commit, working tree clean`。

---

## 完成标准

全部 Task 1-5 的 checkbox 勾选完毕，且：
- `swift build` 成功、`swift test` 全绿。
- 居中标签页显示两个批量按钮，平铺/文档页不显示。
- 五种语言文案齐全（由 `tableCompleteness` 测试保证）。
- 手动验证清单 7 项全部通过。
