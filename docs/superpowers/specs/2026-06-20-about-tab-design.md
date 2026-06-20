# 设置界面「关于」标签页 — 设计文档

- 日期：2026-06-20
- 状态：已与用户确认，待实现
- 目标：在设置界面顶部标签栏新增「关于」标签页，显示当前软件版本号，并提供可点击打开 GitHub 仓库主页的按钮。

## 1. 背景与目标

Plumb 是 macOS 菜单栏窗口管理工具。用户希望在**设置窗口**中增加一个「关于」入口，展示当前软件版本号，
并提供指向 GitHub 仓库主页的可点击按钮，方便用户查看源码与提交问题。

当前设置窗口顶部标签栏有三个标签：居中 / 平铺 / 权限。本次新增第 4 个标签「关于」。

**成功标准（验收）：**

1. 设置窗口顶部标签栏出现「关于」标签（图标 + 文案），可点击切换。
2. 关于标签页显示当前软件版本号（取自 `AppVersion.current`，即 `CFBundleShortVersionString`，当前 1.0.6）。
3. 关于标签页提供一个按钮，点击后在默认浏览器打开 `https://github.com/Lv-0/plumb`。
4. 五种语言（en/zh/ja/es/fr）文案齐全（由既有 `LocalizationTests` 完整性测试保证）。
5. `swift build` 与 `swift test` 通过。

## 2. 关键决策：放置位置与交互

| 决策点 | 选择 | 理由 |
|--------|------|------|
| **放置位置** | 新增第 4 个标签页（居中 / 平铺 / 权限 / 关于） | 信息独立、不挤占现有标签；与三段平铺结构一致。 |
| **GitHub 交互** | 可点击按钮（默认浏览器打开） | macOS 惯例；URL 不显示为长字符串。 |
| **打开 URL** | 仓库主页 `https://github.com/Lv-0/plumb` | 「关于」最自然的指向（README / 源码 / Issues）。 |
| **实现结构** | 新增独立 `AboutSection.swift` 文件 | 与 `PermissionsSection` 等并列，每段独立文件，职责单一。 |

## 3. 架构：新增 `AboutSection` 视图

新增文件 `Sources/Plumb/SettingsUI/AboutSection.swift`，结构与 `PermissionsSection.swift` 平行——
`ScrollView` 包 `VStack`，内部是一张 Liquid Glass 卡片（`Color.primary.opacity(0.04)` 的 `RoundedRectangle` 填充，
不叠 `.glassEffect`，与既有卡片视觉一致）。

```swift
struct AboutSection: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                aboutCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 行 1：应用名 + 版本号
            HStack(spacing: 12) {
                Image(systemName: "drop.fill")       // 与状态栏水滴图标呼应
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.appName)               // "Plumb"（永不本地化）
                        .foregroundStyle(.primary)
                    Text("\(L10n.aboutVersion) \(AppVersion.current.formatted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }

            Divider().opacity(0.25)

            // 行 2：GitHub 按钮行
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.aboutGitHub)
                        .foregroundStyle(.primary)
                    Text(L10n.aboutGitHubHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button(L10n.aboutViewOnGitHub, action: openGitHub)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func openGitHub() {
        if let url = URL(string: "https://github.com/Lv-0/plumb") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

**关键点：**

- **版本号来源**：`AppVersion.current`（已有，读 `CFBundleShortVersionString`）。需给 `AppVersion` 增加一个
  `formatted` 计算属性返回 `"1.0.6"` 形态字符串，避免 UI 手拼 `major.minor.patch`。在 `swift test`/裸可执行
  环境下 `current` 回退到 `(0,0,0)`，UI 会显示「0.0.0」——可接受（与菜单栏「关于 Plumb」原生面板在裸环境下
  的行为一致）。
- **GitHub URL**：硬编码 `https://github.com/Lv-0/plumb`。代码库内已有两处相关定义（`UpdateChecker.appcastURL`
  的 `raw.githubusercontent.com/Lv-0/plumb`、`publish_release.sh` 的 `GITHUB_REPOSITORY=Lv-0/plumb`），但不抽
  公共常量——理由：(a) 用途不同（appcast 是 raw 文件、这里是仓库主页），(b) YAGNI，三处分别各自明确。
- **打开方式**：`NSWorkspace.shared.open(url)`，与 macOS 惯例一致（默认浏览器打开）。

## 4. UI 集成：`SettingsView` 加第 4 个标签

修改 `Sources/Plumb/SettingsUI/SettingsView.swift` 的 `Section` 枚举：

```swift
enum Section: Hashable, CaseIterable {
    case centering, tiling, permissions, about   // 新增 .about
    var title: String {
        switch self {
        // ...
        case .about: return L10n.tabAbout
        }
    }
    var symbol: String {
        switch self {
        // ...
        case .about: return "info.circle"
        }
    }
}
```

并在 `detailView` 的 switch 末尾加：

```swift
case .about:
    AboutSection()
```

`Section.allCases` 自动包含 `.about`，`tabBar` 的 `ForEach` 无需改动——第 4 个胶囊标签自动渲染。

**布局影响**：标签栏从 3 个胶囊变 4 个。每个胶囊 `minWidth: 88`，加 `spacing: 10` 与 `padding(.horizontal, 24)`，
4 个标签总宽 ≈ 88×4 + 10×3 + 24×2 = 460pt，窗口 `minSize` 宽度 760pt，放得下，无布局问题。

## 5. `AppVersion` 增强：`formatted` 计算属性

在 `Sources/Plumb/AppVersion.swift` 加：

```swift
/// "major.minor.patch" 字符串形式，用于 UI 展示。
var formatted: String { "\(major).\(minor).\(patch)" }
```

理由：避免 About 段（及未来其他 UI）手拼三段；集中一处格式化逻辑。`AppVersionTests`（既有）已覆盖解析/比较，
`formatted` 是纯函数，可加一行断言。

## 6. 本地化：`Localization.swift` 新增 5 个 key × 5 语言

现有 `LocalizationTests` 强制每个 key 在五种语言齐全，故新 key 必须五语言齐全。

| Key | en | zh | ja | es | fr |
|-----|----|----|----|----|-----|
| `tabAbout` | About | 关于 | について | Acerca de | À propos |
| `aboutVersion` | Version | 版本 | バージョン | Versión | Version |
| `aboutGitHub` | GitHub | GitHub | GitHub | GitHub | GitHub |
| `aboutGitHubHint` | View source code and report issues. | 查看源代码与提交问题。 | ソースコードの確認と問題の報告。 | Ver código fuente y reportar problemas. | Voir le code source et signaler des problèmes. |
| `aboutViewOnGitHub` | View on GitHub | 在 GitHub 上查看 | GitHub で見る | Ver en GitHub | Voir sur GitHub |

注：`appName` = "Plumb" 已存在且永不本地化，直接复用。`aboutGitHub` 的标题文案就是 "GitHub" 本身——品牌名
不翻译，但保留为独立 key 以便未来可改为带描述的标题。

需在 `L10n.Key` 枚举、`table`（五种语言）、无参访问器三处各添加（与现有 key 完全一致的代码结构）。

## 7. 行为与不变量

- **版本号始终实时读取**：每次切到关于标签页，`AppVersion.current` 重新求值（计算属性，非缓存）。OTA 更新
  重启后自动显示新版本。
- **GitHub 按钮始终可用**：点击即 `NSWorkspace.shared.open`，无网络/权限前置条件（打开浏览器不需要权限）。
- **无持久化**：关于页不读写 `UserDefaults`，无状态。
- **无错误处理**：按钮无失败路径（`URL(string:)` 对硬编码合法 URL 必成功，加 `if let` 仅防御）。

## 8. 测试策略

- **`LocalizationTests`（既有，自动覆盖）**：强制每个 key 五语言齐全。新增 5 个 key 后若任何语言缺失即失败。
- **`AppVersionTests`（既有）**：加 1 行断言 `AppVersion(major:1,minor:0,patch:6).formatted == "1.0.6"`。
- **无 UI 单测**：`AboutSection` 是纯展示视图（`NSWorkspace.shared.open` 不可单测，与 `PermissionsSection`
  调用 `AccessibilityPermission.openSettings()` 同样不做单测的处理一致）。
- **手动集成验证（交付前执行）**：
  1. `scripts/build_app.sh` 产出 `dist/Plumb.app`。
  2. 打开 Plumb → 设置 → 关于标签页。
  3. 确认版本号显示 `1.0.6`（与当前 release 一致）。
  4. 点击「在 GitHub 上查看」→ 默认浏览器打开 `https://github.com/Lv-0/plumb`。
  5. 切换系统语言（en/zh/ja/es/fr），确认标签名与文案正确。

## 9. 范围之外（YAGNI）

- ❌ 不加致谢清单 / 更新日志 / 第三方库列表（需求仅版本号 + GitHub）。
- ❌ 不抽象 GitHub URL 为公共常量（仅一处使用，三处现有定义用途不同）。
- ❌ 不加「检查更新」按钮到关于页（已有菜单栏「检查更新…」入口，重复）。
- ❌ 不加复制版本号 / 复制 URL 功能（决策为「可点击按钮打开」，非复制）。

## 10. 涉及文件清单

| 文件 | 改动 |
|------|------|
| `Sources/Plumb/SettingsUI/AboutSection.swift` | **新增** —— 关于标签页视图。 |
| `Sources/Plumb/SettingsUI/SettingsView.swift` | **修改** —— `Section` 枚举加 `.about`（title/symbol）+ `detailView` switch 加 case。 |
| `Sources/Plumb/AppVersion.swift` | **修改** —— 加 `formatted` 计算属性。 |
| `Sources/Plumb/Localization.swift` | **修改** —— 新增 5 个 key × 5 语言 + 访问器。 |
| `Tests/PlumbTests/AppVersionTests.swift` | **修改** —— 加 1 行 `formatted` 断言。 |
| `Tests/PlumbTests/LocalizationTests.swift` | 无需改 —— 既有完整性测试自动覆盖新 key。 |

## 11. 风险

- **裸可执行环境版本号显示 `0.0.0`**：`swift run`/`swift test` 下 `Bundle.main` 无 `CFBundleShortVersionString`，
  `current` 回退 `(0,0,0)`。打包后的 `.app` 正常显示真实版本。仅影响开发态视觉，不影响功能。与菜单栏
  「关于 Plumb」原生面板在裸环境下的行为一致。
- **标签栏 4 胶囊宽度**：已核算 ≈460pt < 窗口最小宽 760pt，无溢出风险。
