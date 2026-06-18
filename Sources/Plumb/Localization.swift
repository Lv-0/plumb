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
