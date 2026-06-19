# 开机自启动（Launch at Login）— 设计文档

- 日期：2026-06-20
- 状态：已与用户确认，待实现
- 目标：在权限界面新增「开机自启动」开关；打开后 Mac 开机/登录时自动启动 Plumb，关闭后不再自动启动。

## 1. 背景与目标

Plumb 是 macOS 菜单栏窗口管理工具（菜单栏常驻、无 Dock 图标）。用户希望在**权限界面**
中增加一个「开机自启动」选项，使其能在 Mac 启动后自动运行，从而免去每次手动启动。

**成功标准（验收）：**

1. 权限界面（Permissions tab）中存在一个「开机自启动」开关。
2. 开关打开 → Plumb 被注册为登录项；Mac 重启/登录后自动启动 Plumb。
3. 开关关闭 → 取消注册；Mac 重启/登录后不再自动启动 Plumb。
4. 开关状态始终反映系统真实状态（`SMAppService.status`），不维护易失同步的本地布尔镜像。
5. 多语言文案在 en/zh/ja/es/fr 五种语言下完整（由现有 `LocalizationTests` 完整性测试保证）。

## 2. 关键决策：API 选择

| 方案 | 说明 | 取舍 |
|------|------|------|
| **A. `SMAppService.mainApp()`（采用）** | macOS 13+ 的现代 API。`register()`/`unregister()` 即可启用/禁用；`status` 反映实际状态。无需 LaunchAgents 辅助包、无需维护文件路径。 | 简洁、由系统管理生命周期、与 `.app` 生命周期一致。**唯一前提**：需以已签名的 `.app` 包运行（`swift test` 的裸可执行环境下无法生效）。 |
| B. 手写 `~/Library/LaunchAgents/com.comet.plumb.plist` | 传统方案：写入含 app 路径的 plist，路径变动时需同步。 | 易出错、测试面更大、路径每次构建都变。**不采用**。 |

Plumb 目标平台为 macOS 26（`Package.swift` 中 `.macOS(.v26)`），且 `build_app.sh` 产出标准签名
`.app` 包，因此选 **A**。

## 3. 架构：新模块 `LaunchAtLogin`

新增文件 `Sources/Plumb/LaunchAtLogin.swift`，作为 `SMAppService.mainApp()` 的薄封装：

```swift
import ServiceManagement

enum LaunchAtLogin {
    private static let service = SMAppService.mainApp()

    /// 当前是否已注册为登录项。以系统真实状态为准（不读 UserDefaults 镜像）。
    static var isEnabled: Bool {
        switch service.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    /// 启用开机自启动。可能抛错（如非 `.app` 包环境）。
    static func enable() throws  { try service.register() }

    /// 禁用开机自启动。
    static func disable() throws { try service.unregister() }
}
```

**设计要点：**

- **纯静态、无持久化**：系统是唯一真实来源。开关始终反映 `SMAppService.status`，即便用户在
  「系统设置 → 通用 → 登录项」中手动改动，重新打开权限界面也会显示正确值。
- **不写 UserDefaults 镜像**：避免本地布尔与系统状态失同步的经典坑。
- **`enable()`/`disable()` 可抛错**：UI 捕获异常并回滚开关到 `isEnabled` 的真实值，保持一致且不崩溃。

## 4. UI：权限界面新增独立卡片

修改 `Sources/Plumb/SettingsUI/PermissionsSection.swift`，在现有权限卡片**下方**新增一张**独立卡片**，
复用既有 `PillToggle` 组件（与平铺总开关视觉一致）。

布局（延续 Liquid Glass 视觉语言：极淡 `Color.primary.opacity(0.04)` 的 `RoundedRectangle` 填充，
不叠 `.glassEffect`）：

```
权限界面（ScrollView）
┌─ permissionsIntro 文案 ─────────────────────────┐
│                                                  │
│ ┌─ 卡片 1（现有）──────────────────────────────┐ │
│ │ 🛡 辅助功能      ✓ 已授权     [打开设置…]   │ │
│ │ ───────────────────────────────────────────  │ │
│ │ 🎞 屏幕录制      ✓ 已授权     [打开设置…]   │ │
│ └──────────────────────────────────────────────┘ │
│                                                  │
│ ┌─ 卡片 2（新增，开机自启动）──────────────────┐ │
│ │ 🔌 开机自启动              [ ●——  开]       │ │
│ │   Mac 开机后自动启动 Plumb                    │ │
│ └──────────────────────────────────────────────┘ │
```

**实现细节：**

- 图标：SF Symbol `power`（语义贴合「电源/开机启动」）。
- `@State private var launchAtLogin: Bool`：`onAppear` 时由 `LaunchAtLogin.isEnabled` 初始化。
- 开关绑定 + `onChange`：调用 `enable()`/`disable()`，`try` 捕获后回滚到 `LaunchAtLogin.isEnabled`。
- **错误处理**：注册/取消注册失败时不弹窗，开关本身即反馈（回滚到真实状态）。理由：失败多为
  环境性问题（裸可执行、被系统设置手动改动），弹窗噪音大于价值。

## 5. 本地化：`Localization.swift` 新增 2 个 key × 5 语言

现有 `LocalizationTests` 强制「每个 key 在所有语言表中存在」（完整性测试），故新增 key 必须五种语言齐全。

| Key | en | zh | ja | es | fr |
|-----|----|----|----|----|-----|
| `launchAtLogin` | Launch at Login | 开机自启动 | ログイン時に起動 | Abrir al iniciar sesión | Lancer à la connexion |
| `launchAtLoginHint` | Automatically launch Plumb when your Mac starts. | Mac 开机后自动启动 Plumb。 | Mac 起動時に Plumb を自動的に起動します。 | Inicia Plumb automáticamente al encender el Mac. | Lance Plumb automatiquement au démarrage du Mac. |

需同步在 `L10n.Key` 枚举、`table`（五种语言）、以及无参访问器三处各添加对应条目（与现有 key 完全一致的代码结构）。

## 6. 行为与不变量

- **启用（开 → On）**：`SMAppService.mainApp().register()`。成功后状态变 `.enabled`，Mac 登录时启动。
- **禁用（开 → Off）**：`unregister()`。状态变 `.notRegistered`，Mac 登录时不启动。
- **真实来源**：永不持久化到 `UserDefaults`；`onAppear` 与每次切换后都重读 `SMAppService.status`。
- **默认值**：关闭（未注册）。仅由用户显式操作开启。
- **可测试性约束**：`SMAppService.mainApp()` 需真正的签名 `.app` 包，`swift test` 裸可执行环境下会抛错。
  故**单元测试不断言** register/unregister 成功；与 `AccessibilityPermission`/`ScreenCapturePermission`
  处理「不可单测的系统 API」的方式一致。

## 7. 测试策略

- **`LocalizationTests`（既有，自动覆盖）**：已强制每个 key 在五种语言齐全。新增 2 个 key 后，若任何
  语言缺失该测试即失败 —— 无需新建测试文件即可覆盖文案完整性。
- **`LaunchAtLoginTests`（新增，仅静态面）**：验证 facade 不崩溃、`service` 非空等不依赖系统注册
  状态的属性；register/unregister 的断言因环境不可控而跳过/守卫。
- **手动集成验证（写入 spec，交付前执行）**：
  1. `scripts/build_app.sh` 产出 `dist/Plumb.app`。
  2. 打开 Plumb → 权限界面 → 开启「开机自启动」。
  3. 打开「系统设置 → 通用 → 登录项」，确认 Plumb 出现在列表。
  4. 关闭开关 → 确认 Plumb 从登录项列表移除。
  5. （可选）注销/重启 Mac，确认开机后 Plumb 是否按预期启动/不启动。

## 8. 范围之外（YAGNI）

- ❌ 不在菜单栏额外加快捷开关。
- ❌ 无「启动时检查并重新注册」逻辑 —— `SMAppService` 注册是持久的，无需 app 内轮询。
- ❌ 无延迟/启动参数（仅启动，不传参）。
- ❌ 不存本地布尔镜像（系统为唯一真实来源）。

## 9. 涉及文件清单

| 文件 | 改动 |
|------|------|
| `Sources/Plumb/LaunchAtLogin.swift` | **新增** —— `SMAppService.mainApp()` 薄封装。 |
| `Sources/Plumb/SettingsUI/PermissionsSection.swift` | **修改** —— 新增独立「开机自启动」卡片（复用 `PillToggle`）。 |
| `Sources/Plumb/Localization.swift` | **修改** —— 新增 `launchAtLogin`、`launchAtLoginHint` 两个 key × 5 语言 + 访问器。 |
| `Tests/PlumbTests/LaunchAtLoginTests.swift` | **新增** —— facade 静态面测试（register/unregister 跳过）。 |
| `Tests/PlumbTests/LocalizationTests.swift` | 无需改 —— 既有完整性测试自动覆盖新 key。 |

## 10. 风险

- **裸可执行环境（`swift run`/`swift test`）下 `register()` 会抛错**：已由 UI 捕获并回滚开关应对；
  单测不在该路径上做成功断言。
- **用户在系统设置手动改动登录项**：开关每次 `onAppear` 重读状态，能正确反映。
