# UI Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Plumb's UI auto-follow the system language, supporting Chinese (zh), English (en), and Japanese (ja), by introducing a code-resolved `L10n` string table and migrating ~50 hardcoded Chinese strings across 7 files.

**Architecture:** A small `AppLanguage` enum resolves the active language once from `Locale.preferredLanguages` (cached, immutable). A `L10n` namespace exposes typed accessors backed by three flat `[Key: String]` dictionaries (one per language). All UI call sites (SwiftUI `Text`, AppKit menus/alerts, error descriptions) read from `L10n`. No bundle/`Info.plist`/`build_app.sh` coupling — fully in-code, identical under `swift test` and inside the packaged `.app`.

**Tech Stack:** Swift 6.2, SwiftPM, SwiftUI + AppKit, swift-testing framework for tests.

**Spec:** `docs/superpowers/specs/2026-06-18-ui-localization-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Sources/Plumb/Localization.swift` | **Create** | `AppLanguage` resolver + `L10n` namespace + three translation tables |
| `Sources/Plumb/AppDelegate.swift` | Modify | Menu bar items + main menu + alert title → `L10n.*` |
| `Sources/Plumb/WindowCenteringService.swift` | Modify | `WindowCenteringError.errorDescription` → `L10n.err*()` |
| `Sources/Plumb/SettingsWindowController.swift` | Modify | `window.title` → `L10n.settings` |
| `Sources/Plumb/SettingsUI/SettingsView.swift` | Modify | Tab titles + centering footnote → `L10n.*` |
| `Sources/Plumb/SettingsUI/TilingSection.swift` | Modify | Tiling toggle/hints/footnotes → `L10n.*` |
| `Sources/Plumb/SettingsUI/PermissionsSection.swift` | Modify | Permissions rows/labels → `L10n.*` |
| `Sources/Plumb/SettingsUI/AppListSection.swift` | Modify | Search placeholder → `L10n.searchApps` |
| `Sources/Plumb/SettingsUI/AppListRow.swift` | Modify | Accessibility label/value → `L10n.*` |
| `Tests/PlumbTests/LocalizationTests.swift` | **Create** | Resolver mapping + table completeness + format smoke |
| `scripts/build_app.sh` | Modify (optional) | Add `CFBundleLocalizations` to generated `Info.plist` |

---

## Task 1: Create `Localization.swift` (resolver + table + accessors)

**Files:**
- Create: `Sources/Plumb/Localization.swift`
- Test: `Tests/PlumbTests/LocalizationTests.swift` (written in Task 2 against this module)

- [ ] **Step 1: Create `Sources/Plumb/Localization.swift`** with the full content below.

```swift
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Localization (AppLanguage + L10n)
//
// 模块角色：界面文案的多语言解析与查表。
//
// 设计要点：
//   - AppLanguage.current 在首次访问时根据 Locale.preferredLanguages 解析一次并缓存，
//     进程内不可变。符合"启动时自动跟随系统语言"的目标；系统语言变更需重启 App。
//   - L10n 暴露类型安全的访问器，底层是三张 [Key: String] 字典（zh/en/ja）。
//   - 不依赖 .strings / .xcstrings / Bundle：纯代码，swift test 与打包后的 .app 行为一致，
//     无需改动 Info.plist 或 build_app.sh。
// ─────────────────────────────────────────────────────────────────────────────

/// 应用支持的语言。按系统偏好自动解析其一；无匹配时回退到英语。
enum AppLanguage {
    case zh, en, ja

    /// 进程级单次解析，首次访问时缓存。
    static let current: AppLanguage = resolve(from: Locale.preferredLanguages)

    /// 纯函数解析器：按给定偏好顺序返回首个受支持语言，无匹配回退 .en。
    /// 抽离出来便于单测（不依赖系统 Locale 状态）。
    static func resolve(from preferences: [String]) -> AppLanguage {
        for pref in preferences {
            let lang = Locale(identifier: pref).language.languageCode?.identifier ?? ""
            switch lang {
            case "zh": return .zh
            case "ja": return .ja
            case "en": return .en
            default: continue
            }
        }
        return .en
    }
}

/// 界面文案查表命名空间。所有用户可见字符串经由 L10n.* 访问。
enum L10n {
    /// 品牌名，永不本地化。
    static let appName = "Plumb"

    // MARK: - String keys（String-backed，避免拼写错误）

    enum Key: String, CaseIterable {
        // 菜单栏
        case menuSubtitle
        case centerNow
        case settings
        case accessibilityPermission
        case screenRecordingPermission
        case quitApp
        // 主菜单
        case about
        case fileMenu
        case closeWindow
        // 设置标签
        case tabCentering, tabTiling, tabPermissions
        // 居中段
        case centeringFootnote
        case searchApps
        // 平铺段
        case enableAutoTiling
        case enableAutoTilingHint
        case margin
        case marginHint
        case tilingFootnoteOn
        case tilingFootnoteOff
        // 权限段
        case permissionsIntro
        case accessibility
        case screenRecording
        case granted
        case notGranted
        case openSettings
        // 开关 / 无障碍
        case toggleSwitch
        case on, off
        // 错误 / 弹窗
        case centerFailedTitle
        case errAccessibilityPermissionMissing
        case errNoFrontmostApplication
        case errNoWindow
        case errFullscreenWindow
        case errUnableToReadWindowFrame
        case errUnableToWriteWindowSize
        case errUnableToWriteWindowPosition
    }

    // MARK: - 翻译表

    static let table: [AppLanguage: [Key: String]] = [
        .en: [
            .menuSubtitle: "Window Centering · Tiling",
            .centerNow: "Center Now",
            .settings: "Settings…",
            .accessibilityPermission: "Accessibility Permission…",
            .screenRecordingPermission: "Screen Recording Permission…",
            .quitApp: "Quit Plumb",
            .about: "About Plumb",
            .fileMenu: "File",
            .closeWindow: "Close Window",
            .tabCentering: "Centering",
            .tabTiling: "Tiling",
            .tabPermissions: "Permissions",
            .centeringFootnote: "Empty list = center all apps; toggle on to center only selected apps.",
            .searchApps: "Search Apps",
            .enableAutoTiling: "Enable Auto-Tiling",
            .enableAutoTilingHint: "When enabled, checked apps below are auto-tiled onto the screen.",
            .margin: "Margin",
            .marginHint: "Spacing between window and screen edges when tiling.",
            .tilingFootnoteOn: "Check apps to auto-tile; unchecked apps stay centered.",
            .tilingFootnoteOff: "Enable auto-tiling above first.",
            .permissionsIntro: "Plumb needs the following permissions to control window positions.",
            .accessibility: "Accessibility",
            .screenRecording: "Screen Recording",
            .granted: "Granted",
            .notGranted: "Not Granted",
            .openSettings: "Open Settings…",
            .toggleSwitch: "Switch",
            .on: "On",
            .off: "Off",
            .centerFailedTitle: "Window Centering Failed",
            .errAccessibilityPermissionMissing: "Accessibility permission is missing. Grant it in System Settings → Privacy & Security → Accessibility.",
            .errNoFrontmostApplication: "No frontmost application detected.",
            .errNoWindow: "The frontmost app has no operable window.",
            .errFullscreenWindow: "The window is in fullscreen; centering skipped.",
            .errUnableToReadWindowFrame: "Unable to read window position or size.",
            .errUnableToWriteWindowSize: "Unable to set window size (the window may not be resizable).",
            .errUnableToWriteWindowPosition: "Unable to set window position (the window may not be movable).",
        ],
        .zh: [
            .menuSubtitle: "窗口居中 · 平铺",
            .centerNow: "立即居中",
            .settings: "设置…",
            .accessibilityPermission: "辅助功能权限…",
            .screenRecordingPermission: "屏幕录制权限…",
            .quitApp: "退出 Plumb",
            .about: "关于 Plumb",
            .fileMenu: "文件",
            .closeWindow: "关闭窗口",
            .tabCentering: "居中",
            .tabTiling: "平铺",
            .tabPermissions: "权限",
            .centeringFootnote: "空列表 = 居中所有应用；打开开关即仅居中所选应用。",
            .searchApps: "搜索应用",
            .enableAutoTiling: "启用自动平铺",
            .enableAutoTilingHint: "开启后，勾选下方应用时会自动平铺到屏幕。",
            .margin: "边距",
            .marginHint: "平铺时窗口与屏幕边缘之间的间距。",
            .tilingFootnoteOn: "勾选希望自动平铺的应用；未勾选的应用保持居中。",
            .tilingFootnoteOff: "请先在上方开启自动平铺。",
            .permissionsIntro: "Plumb 需要以下权限才能控制窗口位置。",
            .accessibility: "辅助功能",
            .screenRecording: "屏幕录制",
            .granted: "已授权",
            .notGranted: "未授权",
            .openSettings: "打开设置…",
            .toggleSwitch: "开关",
            .on: "开",
            .off: "关",
            .centerFailedTitle: "窗口居中失败",
            .errAccessibilityPermissionMissing: "缺少辅助功能权限，请在“系统设置 -> 隐私与安全性 -> 辅助功能”中授权。",
            .errNoFrontmostApplication: "未检测到前台应用。",
            .errNoWindow: "前台应用没有可操作窗口。",
            .errFullscreenWindow: "当前窗口处于全屏状态，已跳过居中。",
            .errUnableToReadWindowFrame: "无法读取窗口位置或尺寸。",
            .errUnableToWriteWindowSize: "无法设置窗口尺寸（窗口可能不支持调整大小）。",
            .errUnableToWriteWindowPosition: "无法设置窗口位置（窗口可能不可移动）。",
        ],
        .ja: [
            .menuSubtitle: "ウィンドウ中央寄せ · タイル",
            .centerNow: "今すぐ中央寄せ",
            .settings: "設定…",
            .accessibilityPermission: "アクセシビリティ権限…",
            .screenRecordingPermission: "画面収録権限…",
            .quitApp: "Plumb を終了",
            .about: "Plumb について",
            .fileMenu: "ファイル",
            .closeWindow: "ウィンドウを閉じる",
            .tabCentering: "中央寄せ",
            .tabTiling: "タイル",
            .tabPermissions: "権限",
            .centeringFootnote: "空のリスト = すべてのアプリを中央寄せ。オンにすると選択したアプリのみ中央寄せします。",
            .searchApps: "アプリを検索",
            .enableAutoTiling: "自動タイルを有効化",
            .enableAutoTilingHint: "オンにすると、下のチェックしたアプリが自動的に画面にタイル配置されます。",
            .margin: "余白",
            .marginHint: "タイル配置時のウィンドウと画面端の間隔。",
            .tilingFootnoteOn: "自動タイルするアプリにチェックを入れてください。未チェックのアプリは中央寄せのままです。",
            .tilingFootnoteOff: "まず上で自動タイルを有効にしてください。",
            .permissionsIntro: "Plumb がウィンドウの位置を制御するには以下の権限が必要です。",
            .accessibility: "アクセシビリティ",
            .screenRecording: "画面収録",
            .granted: "許可済み",
            .notGranted: "未許可",
            .openSettings: "設定を開く…",
            .toggleSwitch: "スイッチ",
            .on: "オン",
            .off: "オフ",
            .centerFailedTitle: "ウィンドウの中央寄せに失敗しました",
            .errAccessibilityPermissionMissing: "アクセシビリティ権限がありません。「システム設定 → プライバシーとセキュリティ → アクセシビリティ」で許可してください。",
            .errNoFrontmostApplication: "最前面のアプリが検出されませんでした。",
            .errNoWindow: "最前面のアプリに操作可能なウィンドウがありません。",
            .errFullscreenWindow: "ウィンドウはフルスクリーンのため、中央寄せをスキップしました。",
            .errUnableToReadWindowFrame: "ウィンドウの位置またはサイズを読み取れません。",
            .errUnableToWriteWindowSize: "ウィンドウサイズを設定できません（サイズ変更不可の可能性があります）。",
            .errUnableToWriteWindowPosition: "ウィンドウ位置を設定できません（移動不可の可能性があります）。",
        ],
    ]

    // MARK: - 访问器（无参）

    static var menuSubtitle: String { tr(.menuSubtitle) }
    static var centerNow: String { tr(.centerNow) }
    static var settings: String { tr(.settings) }
    static var accessibilityPermission: String { tr(.accessibilityPermission) }
    static var screenRecordingPermission: String { tr(.screenRecordingPermission) }
    static var quitApp: String { tr(.quitApp) }
    static var about: String { tr(.about) }
    static var fileMenu: String { tr(.fileMenu) }
    static var closeWindow: String { tr(.closeWindow) }
    static var tabCentering: String { tr(.tabCentering) }
    static var tabTiling: String { tr(.tabTiling) }
    static var tabPermissions: String { tr(.tabPermissions) }
    static var centeringFootnote: String { tr(.centeringFootnote) }
    static var searchApps: String { tr(.searchApps) }
    static var enableAutoTiling: String { tr(.enableAutoTiling) }
    static var enableAutoTilingHint: String { tr(.enableAutoTilingHint) }
    static var margin: String { tr(.margin) }
    static var marginHint: String { tr(.marginHint) }
    static var tilingFootnoteOn: String { tr(.tilingFootnoteOn) }
    static var tilingFootnoteOff: String { tr(.tilingFootnoteOff) }
    static var permissionsIntro: String { tr(.permissionsIntro) }
    static var accessibility: String { tr(.accessibility) }
    static var screenRecording: String { tr(.screenRecording) }
    static var granted: String { tr(.granted) }
    static var notGranted: String { tr(.notGranted) }
    static var openSettings: String { tr(.openSettings) }
    static var toggleSwitch: String { tr(.toggleSwitch) }
    static var on: String { tr(.on) }
    static var off: String { tr(.off) }
    static var centerFailedTitle: String { tr(.centerFailedTitle) }
    static var errAccessibilityPermissionMissing: String { tr(.errAccessibilityPermissionMissing) }
    static var errNoFrontmostApplication: String { tr(.errNoFrontmostApplication) }
    static var errNoWindow: String { tr(.errNoWindow) }
    static var errFullscreenWindow: String { tr(.errFullscreenWindow) }
    static var errUnableToReadWindowFrame: String { tr(.errUnableToReadWindowFrame) }
    static var errUnableToWriteWindowSize: String { tr(.errUnableToWriteWindowSize) }
    static var errUnableToWriteWindowPosition: String { tr(.errUnableToWriteWindowPosition) }

    // MARK: - 访问器（带参）

    /// 开关的无障碍值描述："开"/"On"/"オン"。
    static func toggleState(_ isOn: Bool) -> String { isOn ? on : off }

    // MARK: - 查表核心

    /// 取当前语言对应文案；缺失则回退到英语（英语表保证完整，详见 LocalizationTests 的完整性测试）。
    private static func tr(_ key: Key) -> String {
        if let v = table[AppLanguage.current]?[key] { return v }
        return table[.en]![key]!
    }
}
```

- [ ] **Step 2: Verify it compiles in isolation**

Run: `swift build`
Expected: BUILD SUCCEEDS (no callers yet, but the module must type-check).

- [ ] **Step 3: Commit**

```bash
git add Sources/Plumb/Localization.swift
git commit -m "feat(l10n): add AppLanguage resolver + L10n string table (zh/en/ja)"
```

---

## Task 2: Tests for resolver + table completeness

**Files:**
- Create: `Tests/PlumbTests/LocalizationTests.swift`

- [ ] **Step 1: Create `Tests/PlumbTests/LocalizationTests.swift`** with the full content below.

```swift
import Testing
@testable import Plumb

@Suite("Localization")
struct LocalizationTests {

    // MARK: - AppLanguage.resolve(from:)

    @Test("zh variants resolve to .zh")
    func zhVariants() {
        #expect(AppLanguage.resolve(from: ["zh-Hans-CN"]) == .zh)
        #expect(AppLanguage.resolve(from: ["zh-Hant-TW"]) == .zh)
        #expect(AppLanguage.resolve(from: ["zh"]) == .zh)
    }

    @Test("en variants resolve to .en")
    func enVariants() {
        #expect(AppLanguage.resolve(from: ["en-US"]) == .en)
        #expect(AppLanguage.resolve(from: ["en-GB"]) == .en)
        #expect(AppLanguage.resolve(from: ["en"]) == .en)
    }

    @Test("ja variants resolve to .ja")
    func jaVariants() {
        #expect(AppLanguage.resolve(from: ["ja-JP"]) == .ja)
        #expect(AppLanguage.resolve(from: ["ja"]) == .ja)
    }

    @Test("unsupported first preference falls through to a later supported one")
    func fallbackWithinList() {
        #expect(AppLanguage.resolve(from: ["fr-FR", "en-US"]) == .en)
        #expect(AppLanguage.resolve(from: ["de-DE", "ja-JP"]) == .ja)
    }

    @Test("no supported language in list falls back to .en")
    func noMatchFallsBackToEnglish() {
        #expect(AppLanguage.resolve(from: ["fr-FR"]) == .en)
        #expect(AppLanguage.resolve(from: ["ko-KR", "fr-FR"]) == .en)
    }

    @Test("first user preference wins when multiple supported present")
    func firstPreferenceWins() {
        #expect(AppLanguage.resolve(from: ["ja", "zh"]) == .ja)
        #expect(AppLanguage.resolve(from: ["zh", "en"]) == .zh)
    }

    @Test("empty preference list falls back to .en")
    func emptyListFallback() {
        #expect(AppLanguage.resolve(from: []) == .en)
    }

    // MARK: - Table completeness

    @Test("every key is present and non-empty in every supported language")
    func tableCompleteness() {
        for lang in [AppLanguage.zh, .en, .ja] {
            let dict = try #require(L10n.table[lang])
            for key in L10n.Key.allCases {
                let v = try #require(dict[key], "Missing key \(key.rawValue) in \(lang)")
                #expect(!v.isEmpty, "Empty value for key \(key.rawValue) in \(lang)")
            }
        }
    }

    // MARK: - Accessor smoke (renders without crashing, returns localized value)

    @Test("toggleState mirrors on/off")
    func toggleStateMirror() {
        #expect(L10n.toggleState(true) == L10n.on)
        #expect(L10n.toggleState(false) == L10n.off)
    }

    @Test("appName is the unlocalized brand constant")
    func appNameUnlocalized() {
        #expect(L10n.appName == "Plumb")
    }
}
```

- [ ] **Step 2: Run tests — expect PASS**

Run: `swift test --filter LocalizationTests`
Expected: All tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/PlumbTests/LocalizationTests.swift
git commit -m "test(l10n): resolver mapping, table completeness, accessor smoke"
```

---

## Task 3: Migrate `AppDelegate.swift` (menu bar + main menu + alert)

**Files:**
- Modify: `Sources/Plumb/AppDelegate.swift`

- [ ] **Step 1: Replace the alert title string.** In `centerNowInternal(showAlertOnFailure:selectionPolicy:)`, change line 58:

Old:
```swift
                showAlert(title: "窗口居中失败", message: error.localizedDescription)
```
New:
```swift
                showAlert(title: L10n.centerFailedTitle, message: error.localizedDescription)
```

- [ ] **Step 2: Replace the main-menu literals** in `setupMainMenu()`:

Old (line 99):
```swift
        appMenu.addItem(withTitle: "关于 Plumb", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
```
New:
```swift
        appMenu.addItem(withTitle: L10n.about, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
```

Old (line 101):
```swift
        appMenu.addItem(withTitle: "退出 Plumb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
```
New:
```swift
        appMenu.addItem(withTitle: L10n.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
```

Old (lines 105-106):
```swift
        let fileMenuItem = mainMenu.addItem(withTitle: "文件", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "文件")
```
New:
```swift
        let fileMenuItem = mainMenu.addItem(withTitle: L10n.fileMenu, action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L10n.fileMenu)
```

Old (line 107):
```swift
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
```
New:
```swift
        fileMenu.addItem(withTitle: L10n.closeWindow, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
```

- [ ] **Step 3: Replace the status-menu literals** in `setupStatusItem()`:

Old (line 134):
```swift
        let subtitle = menu.addItem(withTitle: "  窗口居中 · 平铺", action: nil, keyEquivalent: "")
```
New:
```swift
        let subtitle = menu.addItem(withTitle: "  " + L10n.menuSubtitle, action: nil, keyEquivalent: "")
```
(The leading two-space indent is preserved as before.)

Old (line 139):
```swift
        let centerItem = menu.addItem(withTitle: "立即居中", action: #selector(centerNow), keyEquivalent: "")
```
New:
```swift
        let centerItem = menu.addItem(withTitle: L10n.centerNow, action: #selector(centerNow), keyEquivalent: "")
```

Old (line 144):
```swift
        let settingsItem = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
```
New:
```swift
        let settingsItem = menu.addItem(withTitle: L10n.settings, action: #selector(openSettings), keyEquivalent: ",")
```

Old (line 150):
```swift
        let accItem = menu.addItem(withTitle: "辅助功能权限…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
```
New:
```swift
        let accItem = menu.addItem(withTitle: L10n.accessibilityPermission, action: #selector(openAccessibilitySettings), keyEquivalent: "")
```

Old (line 154):
```swift
        let scrItem = menu.addItem(withTitle: "屏幕录制权限…", action: #selector(openScreenCaptureSettings), keyEquivalent: "")
```
New:
```swift
        let scrItem = menu.addItem(withTitle: L10n.screenRecordingPermission, action: #selector(openScreenCaptureSettings), keyEquivalent: "")
```

Old (line 159):
```swift
        let quitItem = menu.addItem(withTitle: "退出 Plumb", action: #selector(quitApp), keyEquivalent: "q")
```
New:
```swift
        let quitItem = menu.addItem(withTitle: L10n.quitApp, action: #selector(quitApp), keyEquivalent: "q")
```

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Plumb/AppDelegate.swift
git commit -m "feat(l10n): migrate AppDelegate menus + alert to L10n"
```

---

## Task 4: Migrate `WindowCenteringService.swift` (error descriptions)

**Files:**
- Modify: `Sources/Plumb/WindowCenteringService.swift:43-60`

- [ ] **Step 1: Replace the `errorDescription` switch body.**

Old (lines 43-60):
```swift
    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "缺少辅助功能权限，请在“系统设置 -> 隐私与安全性 -> 辅助功能”中授权。"
        case .noFrontmostApplication:
            return "未检测到前台应用。"
        case .noWindow:
            return "前台应用没有可操作窗口。"
        case .fullscreenWindow:
            return "当前窗口处于全屏状态，已跳过居中。"
        case .unableToReadWindowFrame:
            return "无法读取窗口位置或尺寸。"
        case .unableToWriteWindowSize:
            return "无法设置窗口尺寸（窗口可能不支持调整大小）。"
        case .unableToWriteWindowPosition:
            return "无法设置窗口位置（窗口可能不可移动）。"
        }
    }
```
New:
```swift
    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return L10n.errAccessibilityPermissionMissing
        case .noFrontmostApplication:
            return L10n.errNoFrontmostApplication
        case .noWindow:
            return L10n.errNoWindow
        case .fullscreenWindow:
            return L10n.errFullscreenWindow
        case .unableToReadWindowFrame:
            return L10n.errUnableToReadWindowFrame
        case .unableToWriteWindowSize:
            return L10n.errUnableToWriteWindowSize
        case .unableToWriteWindowPosition:
            return L10n.errUnableToWriteWindowPosition
        }
    }
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDS.

- [ ] **Step 3: Commit**

```bash
git add Sources/Plumb/WindowCenteringService.swift
git commit -m "feat(l10n): migrate WindowCenteringError descriptions to L10n"
```

---

## Task 5: Migrate `SettingsWindowController.swift` (window title)

**Files:**
- Modify: `Sources/Plumb/SettingsWindowController.swift:39`

- [ ] **Step 1: Replace the window title.**

Old (line 39):
```swift
        window.title = "设置"
```
New:
```swift
        window.title = L10n.settings
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDS.

- [ ] **Step 3: Commit**

```bash
git add Sources/Plumb/SettingsWindowController.swift
git commit -m "feat(l10n): migrate settings window title to L10n"
```

---

## Task 6: Migrate `SettingsUI/SettingsView.swift` (tab titles + centering footnote)

**Files:**
- Modify: `Sources/Plumb/SettingsUI/SettingsView.swift`

- [ ] **Step 1: Replace the `Section.title` switch.**

Old (lines 38-44):
```swift
        var title: String {
            switch self {
            case .centering: return "居中"
            case .tiling: return "平铺"
            case .permissions: return "权限"
            }
        }
```
New:
```swift
        var title: String {
            switch self {
            case .centering: return L10n.tabCentering
            case .tiling: return L10n.tabTiling
            case .permissions: return L10n.tabPermissions
            }
        }
```

- [ ] **Step 2: Replace the centering footnote.**

Old (lines 155-158):
```swift
            CenteringSection(
                footnote: "空列表 = 居中所有应用；打开开关即仅居中所选应用。",
                selected: $settings.centeredBundleIDs,
                apps: apps
            )
```
New:
```swift
            CenteringSection(
                footnote: L10n.centeringFootnote,
                selected: $settings.centeredBundleIDs,
                apps: apps
            )
```

- [ ] **Step 3: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDS.

- [ ] **Step 4: Commit**

```bash
git add Sources/Plumb/SettingsUI/SettingsView.swift
git commit -m "feat(l10n): migrate SettingsView tab titles + centering footnote"
```

---

## Task 7: Migrate `SettingsUI/TilingSection.swift`

**Files:**
- Modify: `Sources/Plumb/SettingsUI/TilingSection.swift`

- [ ] **Step 1: Replace the enable-toggle title and hint.**

Old (lines 33-35):
```swift
                            Text("启用自动平铺")
                                .foregroundStyle(.primary)
                            Text("开启后，勾选下方应用时会自动平铺到屏幕。")
```
New:
```swift
                            Text(L10n.enableAutoTiling)
                                .foregroundStyle(.primary)
                            Text(L10n.enableAutoTilingHint)
```

- [ ] **Step 2: Replace the margin label and hint.**

Old (line 49):
```swift
                            Text("边距")
```
New:
```swift
                            Text(L10n.margin)
```

Old (lines 59-60):
```swift
                        Text("平铺时窗口与屏幕边缘之间的间距。")
                            .font(.caption)
```
New:
```swift
                        Text(L10n.marginHint)
                            .font(.caption)
```

- [ ] **Step 3: Replace the AppListSection footnote ternary.**

Old (lines 75-77):
```swift
                    footnote: settings.isEnabled
                        ? "勾选希望自动平铺的应用；未勾选的应用保持居中。"
                        : "请先在上方开启自动平铺。",
```
New:
```swift
                    footnote: settings.isEnabled
                        ? L10n.tilingFootnoteOn
                        : L10n.tilingFootnoteOff,
```

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Plumb/SettingsUI/TilingSection.swift
git commit -m "feat(l10n): migrate TilingSection strings to L10n"
```

---

## Task 8: Migrate `SettingsUI/PermissionsSection.swift`

**Files:**
- Modify: `Sources/Plumb/SettingsUI/PermissionsSection.swift`

- [ ] **Step 1: Replace the intro text.**

Old (line 23):
```swift
                Text("Plumb 需要以下权限才能控制窗口位置。")
```
New:
```swift
                Text(L10n.permissionsIntro)
```

- [ ] **Step 2: Replace the two permission row titles.**

Old (lines 30-31):
```swift
                        title: "辅助功能",
```
New:
```swift
                        title: L10n.accessibility,
```

Old (lines 37-38):
```swift
                        title: "屏幕录制",
```
New:
```swift
                        title: L10n.screenRecording,
```

- [ ] **Step 3: Replace the granted/not-granted text and the open-settings button.**

Old (line 69):
```swift
                Text(granted ? "已授权" : "未授权")
```
New:
```swift
                Text(granted ? L10n.granted : L10n.notGranted)
```

Old (line 74):
```swift
            Button("打开设置…", action: action)
```
New:
```swift
            Button(L10n.openSettings, action: action)
```

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Plumb/SettingsUI/PermissionsSection.swift
git commit -m "feat(l10n): migrate PermissionsSection strings to L10n"
```

---

## Task 9: Migrate `SettingsUI/AppListSection.swift` (search placeholder)

**Files:**
- Modify: `Sources/Plumb/SettingsUI/AppListSection.swift:65`

- [ ] **Step 1: Replace the search placeholder.**

Old (line 65):
```swift
                    TextField("搜索应用", text: $query)
```
New:
```swift
                    TextField(L10n.searchApps, text: $query)
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDS.

- [ ] **Step 3: Commit**

```bash
git add Sources/Plumb/SettingsUI/AppListSection.swift
git commit -m "feat(l10n): migrate search placeholder to L10n"
```

---

## Task 10: Migrate `SettingsUI/AppListRow.swift` (accessibility label/value)

**Files:**
- Modify: `Sources/Plumb/SettingsUI/AppListRow.swift:110-111`

- [ ] **Step 1: Replace the accessibility label and value.**

Old (lines 110-111):
```swift
        .accessibilityLabel(Text("开关"))
        .accessibilityValue(Text(isOn ? "开" : "关"))
```
New:
```swift
        .accessibilityLabel(Text(L10n.toggleSwitch))
        .accessibilityValue(Text(L10n.toggleState(isOn)))
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDS.

- [ ] **Step 3: Commit**

```bash
git add Sources/Plumb/SettingsUI/AppListRow.swift
git commit -m "feat(l10n): migrate PillToggle accessibility strings to L10n"
```

---

## Task 11: Full regression — build + test + leftover-string scan

**Files:** none modified (verification only).

- [ ] **Step 1: Clean release build**

Run: `swift build -c release`
Expected: BUILD SUCCEEDS.

- [ ] **Step 2: Run the full test suite**

Run: `swift test`
Expected: All existing tests + `LocalizationTests` PASS.

- [ ] **Step 3: Scan for any remaining user-facing Chinese literals that were missed.**

Run: `rg -n '"[\u4e00-\u9fff]' Sources/Plumb`
Expected: Only matches in **comments** (lines starting with `//` or inside `/* */`). Confirm any non-comment hits are non-user-facing (e.g. diagnostic logs, SelfTest developer tooling — which are explicitly out of scope). If a user-facing literal remains, migrate it.

- [ ] **Step 4: Final commit if scan surfaced anything**

```bash
git add -A
git commit -m "chore(l10n): cleanup any residual hardcoded strings"
```
(If the scan was clean, skip this step — no empty commit.)

---

## Task 12 (optional): Declare supported languages in `Info.plist`

**Files:**
- Modify: `scripts/build_app.sh`

- [ ] **Step 1: Add `CFBundleLocalizations` to the generated `Info.plist`.** Insert before the closing `</dict>` (after the `NSHumanReadableCopyright` entry):

Old:
```
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © $(date +%Y)</string>
</dict>
```
New:
```
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © $(date +%Y)</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh</string>
    <string>en</string>
    <string>ja</string>
  </array>
</dict>
```

- [ ] **Step 2: Verify the script still generates a valid plist**

Run: `bash scripts/build_app.sh`
Expected: Completes with `[4/4] 完成: dist/Plumb.app` and no errors. (Optional: `plutil -lint dist/Plumb.app/Contents/Info.plist` should report OK.)

- [ ] **Step 3: Commit**

```bash
git add scripts/build_app.sh
git commit -m "chore(build): declare CFBundleLocalizations zh/en/ja"
```

---

## Self-Review (completed during planning)

**1. Spec coverage:**
- §2.1 language detection → Task 1 (`AppLanguage.resolve`).
- §2.2 string table → Task 1 (`L10n` + table).
- §2.3 call-site migration → Tasks 3–10 cover all 7 files listed in the spec's File Structure table.
- §2.4 `Info.plist` optional → Task 12.
- §3 string inventory → every key in the inventory appears in the Task 1 table, keyed identically.
- §4 testing → Task 2 implements resolver mapping, table completeness, accessor smoke.
- §6 verification Done criteria → Task 11.

**2. Placeholder scan:** None. Every step has concrete code/commands; no "TBD"/"implement later".

**3. Type consistency:** Key names are identical between the `Key` enum (Task 1), the three tables (Task 1), the accessors (Task 1), and the call sites (Tasks 3–10). `L10n.toggleState(_ isOn: Bool)` signature matches usage in Task 10. `AppLanguage.resolve(from:)` signature matches Task 2 tests.
