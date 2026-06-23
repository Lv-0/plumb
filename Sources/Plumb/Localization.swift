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
    case zh, en, es, fr, ja

    /// 进程级单次解析，首次访问时缓存。
    static let current: AppLanguage = resolve(from: Locale.preferredLanguages)

    /// 纯函数解析器：按给定偏好顺序返回首个受支持语言，无匹配回退 .en。
    /// 抽离出来便于单测（不依赖系统 Locale 状态）。
    static func resolve(from preferences: [String]) -> AppLanguage {
        for pref in preferences {
            let lang = Locale(identifier: pref).language.languageCode?.identifier ?? ""
            switch lang {
            case "zh": return .zh
            case "es": return .es
            case "fr": return .fr
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
        case bulkSelectAll
        case bulkDeselectAll
        // 平铺段
        case enableAutoTiling
        case enableAutoTilingHint
        case margin
        case marginHint
        case tilingFootnoteOn
        case tilingFootnoteOff
        // 文档选择器段
        case documentChooserTitle
        case documentChooserFootnote
        case documentChooserEmptyHint
        // 平铺子标签（双页切换）
        case tilingSubtabAllowlist
        case tilingSubtabDocument
        // 文档类 App 行内置灰提示（未加入平铺白名单时）
        case documentChooserDisabledHint
        // 权限段
        case permissionsIntro
        case accessibility
        case screenRecording
        case granted
        case notGranted
        case openSettings
        case launchAtLogin
        case launchAtLoginHint
        // 关于段
        case tabAbout
        case aboutVersion
        case aboutGitHub
        case aboutGitHubHint
        case aboutViewOnGitHub
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
        // OTA 更新
        case otaCheckForUpdates
        case otaUpToDate
        case otaCheckFailed
        case otaCheckFailedHint
        case otaNewVersionTitle
        case otaUpdateNow
        case otaCancel
        case otaDownloadFailed
        case otaDownloadFailedHint
        case otaInstallingTitle
        case otaInstallingMessage
        case otaInstallDone
        case otaInstallCanceled
        case otaInstallFailed
        // OTA 下载进度
        case otaDownloadingTitle
        case otaDownloadingMessage
        case otaDownloadingSize
        case otaDownloadCanceled
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
            .bulkSelectAll: "Select All",
            .bulkDeselectAll: "Deselect All",
            .enableAutoTiling: "Enable Auto-Tiling",
            .enableAutoTilingHint: "When enabled, checked apps below are auto-tiled onto the screen.",
            .margin: "Margin",
            .marginHint: "Spacing between window and screen edges when tiling.",
            .tilingFootnoteOn: "Check apps to auto-tile; unchecked apps stay centered.",
            .tilingFootnoteOff: "Enable auto-tiling above first.",
            .documentChooserTitle: "Document Apps",
            .documentChooserFootnote: "These apps show a template/file picker first — it's centered but not tiled; only the opened document gets tiled.",
            .documentChooserEmptyHint: "Add an app to the tiling list above to configure it here.",
            .tilingSubtabAllowlist: "Tiling Apps",
            .tilingSubtabDocument: "Document Apps",
            .documentChooserDisabledHint: "Add to tiling list first",
            .permissionsIntro: "Plumb needs the following permissions to control window positions.",
            .accessibility: "Accessibility",
            .screenRecording: "Screen Recording",
            .granted: "Granted",
            .notGranted: "Not Granted",
            .openSettings: "Open Settings…",
            .launchAtLogin: "Launch at Login",
            .launchAtLoginHint: "Automatically launch Plumb when your Mac starts.",
            .tabAbout: "About",
            .aboutVersion: "Version",
            .aboutGitHub: "GitHub",
            .aboutGitHubHint: "View source code and report issues.",
            .aboutViewOnGitHub: "View on GitHub",
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
            .otaCheckForUpdates: "Check for Updates…",
            .otaUpToDate: "You're up to date.",
            .otaCheckFailed: "Update check failed.",
            .otaCheckFailedHint: "Check your network connection and try again.",
            .otaNewVersionTitle: "Plumb %@ is available",
            .otaUpdateNow: "Update Now",
            .otaCancel: "Cancel",
            .otaDownloadFailed: "Download failed.",
            .otaDownloadFailedHint: "The update package may be damaged. Try again later or download manually from GitHub.",
            .otaInstallingTitle: "Installing Update",
            .otaInstallingMessage: "Replacing Plumb…",
            .otaInstallDone: "Done. Relaunching…",
            .otaInstallCanceled: "Installation canceled. The previous version was kept.",
            .otaInstallFailed: "Installation failed. The previous version was kept.",
            .otaDownloadingTitle: "Updating Plumb",
            .otaDownloadingMessage: "Downloading Plumb %@…",
            .otaDownloadingSize: "%1$@ of %2$@",
            .otaDownloadCanceled: "Download canceled.",
        ],
        .es: [
            .menuSubtitle: "Centrado de ventanas · Mosaico",
            .centerNow: "Centrar ahora",
            .settings: "Ajustes…",
            .accessibilityPermission: "Permiso de accesibilidad…",
            .screenRecordingPermission: "Permiso de grabación de pantalla…",
            .quitApp: "Salir de Plumb",
            .about: "Acerca de Plumb",
            .fileMenu: "Archivo",
            .closeWindow: "Cerrar ventana",
            .tabCentering: "Centrado",
            .tabTiling: "Mosaico",
            .tabPermissions: "Permisos",
            .centeringFootnote: "Lista vacía = centrar todas las apps; activa el interruptor para centrar solo las apps seleccionadas.",
            .searchApps: "Buscar apps",
            .bulkSelectAll: "Seleccionar todo",
            .bulkDeselectAll: "Deseleccionar todo",
            .enableAutoTiling: "Activar mosaico automático",
            .enableAutoTilingHint: "Cuando está activado, las apps marcadas abajo se colocan en mosaico en la pantalla automáticamente.",
            .margin: "Margen",
            .marginHint: "Espacio entre la ventana y los bordes de la pantalla al colocar en mosaico.",
            .tilingFootnoteOn: "Marca las apps que quieres en mosaico; las no marcadas permanecen centradas.",
            .tilingFootnoteOff: "Activa primero el mosaico automático arriba.",
            .documentChooserTitle: "Apps de documentos",
            .documentChooserFootnote: "Estas apps muestran primero un selector de plantillas/archivos: se centra pero no se coloca en mosaico; solo el documento abierto se coloca en mosaico.",
            .documentChooserEmptyHint: "Añade una app a la lista de mosaico de arriba para configurarla aquí.",
            .tilingSubtabAllowlist: "Apps en mosaico",
            .tilingSubtabDocument: "Apps de documentos",
            .documentChooserDisabledHint: "Añade primero a la lista de mosaico",
            .permissionsIntro: "Plumb necesita los siguientes permisos para controlar las posiciones de las ventanas.",
            .accessibility: "Accesibilidad",
            .screenRecording: "Grabación de pantalla",
            .granted: "Concedido",
            .notGranted: "No concedido",
            .openSettings: "Abrir ajustes…",
            .launchAtLogin: "Abrir al iniciar sesión",
            .launchAtLoginHint: "Inicia Plumb automáticamente al encender el Mac.",
            .tabAbout: "Acerca de",
            .aboutVersion: "Versión",
            .aboutGitHub: "GitHub",
            .aboutGitHubHint: "Ver código fuente y reportar problemas.",
            .aboutViewOnGitHub: "Ver en GitHub",
            .toggleSwitch: "Interruptor",
            .on: "Activado",
            .off: "Desactivado",
            .centerFailedTitle: "Error al centrar la ventana",
            .errAccessibilityPermissionMissing: "Falta el permiso de accesibilidad. Concédelo en Ajustes del sistema → Privacidad y seguridad → Accesibilidad.",
            .errNoFrontmostApplication: "No se detectó ninguna aplicación en primer plano.",
            .errNoWindow: "La app en primer plano no tiene ninguna ventana operable.",
            .errFullscreenWindow: "La ventana está en pantalla completa; se omitió el centrado.",
            .errUnableToReadWindowFrame: "No se pudo leer la posición o el tamaño de la ventana.",
            .errUnableToWriteWindowSize: "No se pudo establecer el tamaño de la ventana (puede que no sea redimensionable).",
            .errUnableToWriteWindowPosition: "No se pudo establecer la posición de la ventana (puede que no se pueda mover).",
            .otaCheckForUpdates: "Buscar actualizaciones…",
            .otaUpToDate: "Ya tienes la última versión.",
            .otaCheckFailed: "Error al comprobar actualizaciones.",
            .otaCheckFailedHint: "Comprueba tu conexión de red e inténtalo de nuevo.",
            .otaNewVersionTitle: "Plumb %@ está disponible",
            .otaUpdateNow: "Actualizar ahora",
            .otaCancel: "Cancelar",
            .otaDownloadFailed: "Error en la descarga.",
            .otaDownloadFailedHint: "El paquete puede estar dañado. Inténtalo más tarde o descárgalo manualmente desde GitHub.",
            .otaInstallingTitle: "Instalando actualización",
            .otaInstallingMessage: "Reemplazando Plumb…",
            .otaInstallDone: "Listo. Reiniciando…",
            .otaInstallCanceled: "Instalación cancelada. Se mantuvo la versión anterior.",
            .otaInstallFailed: "Error en la instalación. Se mantuvo la versión anterior.",
            .otaDownloadingTitle: "Actualizando Plumb",
            .otaDownloadingMessage: "Descargando Plumb %@…",
            .otaDownloadingSize: "%1$@ de %2$@",
            .otaDownloadCanceled: "Descarga cancelada.",
        ],
        .fr: [
            .menuSubtitle: "Centrage de fenêtre · Mosaïque",
            .centerNow: "Centrer maintenant",
            .settings: "Réglages…",
            .accessibilityPermission: "Permission d'accèsibilité…",
            .screenRecordingPermission: "Permission d'enregistrement d'écran…",
            .quitApp: "Quitter Plumb",
            .about: "À propos de Plumb",
            .fileMenu: "Fichier",
            .closeWindow: "Fermer la fenêtre",
            .tabCentering: "Centrage",
            .tabTiling: "Mosaïque",
            .tabPermissions: "Permissions",
            .centeringFootnote: "Liste vide = centrer toutes les apps ; activez l'interrupteur pour ne centrer que les apps sélectionnées.",
            .searchApps: "Rechercher des apps",
            .bulkSelectAll: "Tout sélectionner",
            .bulkDeselectAll: "Tout désélectionner",
            .enableAutoTiling: "Activer la mosaïque automatique",
            .enableAutoTilingHint: "Lorsque c'est activé, les apps cochées ci-dessous sont placées en mosaïque à l'écran automatiquement.",
            .margin: "Marge",
            .marginHint: "Espace entre la fenêtre et les bords de l'écran lors de la mosaïque.",
            .tilingFootnoteOn: "Cochez les apps à placer en mosaïque ; les apps non cochées restent centrées.",
            .tilingFootnoteOff: "Activez d'abord la mosaïque automatique ci-dessus.",
            .documentChooserTitle: "Apps de documents",
            .documentChooserFootnote: "Ces apps affichent d'abord un sélecteur de modèles/fichiers : il est centré mais pas en mosaïque ; seul le document ouvert est placé en mosaïque.",
            .documentChooserEmptyHint: "Ajoutez une app à la liste de mosaïque ci-dessus pour la configurer ici.",
            .tilingSubtabAllowlist: "Apps en mosaïque",
            .tilingSubtabDocument: "Apps de documents",
            .documentChooserDisabledHint: "Ajoutez d'abord à la liste de mosaïque",
            .permissionsIntro: "Plumb a besoin des permissions suivantes pour contrôler les positions des fenêtres.",
            .accessibility: "Accessibilité",
            .screenRecording: "Enregistrement d'écran",
            .granted: "Accordée",
            .notGranted: "Non accordée",
            .openSettings: "Ouvrir les réglages…",
            .launchAtLogin: "Lancer à la connexion",
            .launchAtLoginHint: "Lance Plumb automatiquement au démarrage du Mac.",
            .tabAbout: "À propos",
            .aboutVersion: "Version",
            .aboutGitHub: "GitHub",
            .aboutGitHubHint: "Voir le code source et signaler des problèmes.",
            .aboutViewOnGitHub: "Voir sur GitHub",
            .toggleSwitch: "Interrupteur",
            .on: "Activé",
            .off: "Désactivé",
            .centerFailedTitle: "Échec du centrage de la fenêtre",
            .errAccessibilityPermissionMissing: "La permission d'accessibilité manque. Accordez-la dans Réglages Système → Confidentialité et sécurité → Accessibilité.",
            .errNoFrontmostApplication: "Aucune application au premier plan détectée.",
            .errNoWindow: "L'app au premier plan n'a aucune fenêtre opérable.",
            .errFullscreenWindow: "La fenêtre est en plein écran ; centrage ignoré.",
            .errUnableToReadWindowFrame: "Impossible de lire la position ou la taille de la fenêtre.",
            .errUnableToWriteWindowSize: "Impossible de définir la taille de la fenêtre (elle n'est peut-être pas redimensionnable).",
            .errUnableToWriteWindowPosition: "Impossible de définir la position de la fenêtre (elle n'est peut-être pas déplaçable).",
            .otaCheckForUpdates: "Rechercher des mises à jour…",
            .otaUpToDate: "Vous êtes à jour.",
            .otaCheckFailed: "Échec de la vérification des mises à jour.",
            .otaCheckFailedHint: "Vérifiez votre connexion réseau et réessayez.",
            .otaNewVersionTitle: "Plumb %@ est disponible",
            .otaUpdateNow: "Mettre à jour",
            .otaCancel: "Annuler",
            .otaDownloadFailed: "Échec du téléchargement.",
            .otaDownloadFailedHint: "Le paquet est peut-être endommagé. Réessayez plus tard ou téléchargez-le manuellement depuis GitHub.",
            .otaInstallingTitle: "Installation de la mise à jour",
            .otaInstallingMessage: "Remplacement de Plumb…",
            .otaInstallDone: "Terminé. Redémarrage…",
            .otaInstallCanceled: "Installation annulée. La version précédente a été conservée.",
            .otaInstallFailed: "Échec de l'installation. La version précédente a été conservée.",
            .otaDownloadingTitle: "Mise à jour de Plumb",
            .otaDownloadingMessage: "Téléchargement de Plumb %@…",
            .otaDownloadingSize: "%1$@ sur %2$@",
            .otaDownloadCanceled: "Téléchargement annulé.",
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
            .bulkSelectAll: "全部打开",
            .bulkDeselectAll: "全部关闭",
            .enableAutoTiling: "启用自动平铺",
            .enableAutoTilingHint: "开启后，勾选下方应用时会自动平铺到屏幕。",
            .margin: "边距",
            .marginHint: "平铺时窗口与屏幕边缘之间的间距。",
            .tilingFootnoteOn: "勾选希望自动平铺的应用；未勾选的应用保持居中。",
            .tilingFootnoteOff: "请先在上方开启自动平铺。",
            .documentChooserTitle: "文档类 App",
            .documentChooserFootnote: "这些 App 打开模板或文件列表时仅居中、不平铺；只有打开的文档窗口才会被平铺。",
            .documentChooserEmptyHint: "先将 App 加入上方平铺列表，才能在此配置。",
            .tilingSubtabAllowlist: "平铺应用列表",
            .tilingSubtabDocument: "文档类 App",
            .documentChooserDisabledHint: "先加入平铺列表",
            .permissionsIntro: "Plumb 需要以下权限才能控制窗口位置。",
            .accessibility: "辅助功能",
            .screenRecording: "屏幕录制",
            .granted: "已授权",
            .notGranted: "未授权",
            .openSettings: "打开设置…",
            .launchAtLogin: "开机自启动",
            .launchAtLoginHint: "Mac 开机后自动启动 Plumb。",
            .tabAbout: "关于",
            .aboutVersion: "版本",
            .aboutGitHub: "GitHub",
            .aboutGitHubHint: "查看源代码与提交问题。",
            .aboutViewOnGitHub: "在 GitHub 上查看",
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
            .otaCheckForUpdates: "检查更新…",
            .otaUpToDate: "已是最新版本。",
            .otaCheckFailed: "检查更新失败。",
            .otaCheckFailedHint: "请检查网络连接后重试。",
            .otaNewVersionTitle: "Plumb %@ 已发布",
            .otaUpdateNow: "立即更新",
            .otaCancel: "取消",
            .otaDownloadFailed: "下载失败。",
            .otaDownloadFailedHint: "更新包可能已损坏。请稍后重试，或前往 GitHub 手动下载。",
            .otaInstallingTitle: "正在安装更新",
            .otaInstallingMessage: "正在替换 Plumb…",
            .otaInstallDone: "完成，正在重启…",
            .otaInstallCanceled: "安装已取消，已保留原版本。",
            .otaInstallFailed: "安装失败，已保留原版本。",
            .otaDownloadingTitle: "正在更新 Plumb",
            .otaDownloadingMessage: "正在下载 Plumb %@…",
            .otaDownloadingSize: "%1$@ / %2$@",
            .otaDownloadCanceled: "下载已取消。",
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
            .bulkSelectAll: "すべて選択",
            .bulkDeselectAll: "すべて解除",
            .enableAutoTiling: "自動タイルを有効化",
            .enableAutoTilingHint: "オンにすると、下のチェックしたアプリが自動的に画面にタイル配置されます。",
            .margin: "余白",
            .marginHint: "タイル配置時のウィンドウと画面端の間隔。",
            .tilingFootnoteOn: "自動タイルするアプリにチェックを入れてください。未チェックのアプリは中央寄せのままです。",
            .tilingFootnoteOff: "まず上で自動タイルを有効にしてください。",
            .documentChooserTitle: "書類アプリ",
            .documentChooserFootnote: "これらのアプリはテンプレートやファイル選択画面を先に表示します。選択画面は中央寄せのみでタイル化せず、開いた書類のみタイル化します。",
            .documentChooserEmptyHint: "上のタイリングリストにアプリを追加すると、ここで設定できます。",
            .tilingSubtabAllowlist: "タイル対象アプリ",
            .tilingSubtabDocument: "書類アプリ",
            .documentChooserDisabledHint: "まずタイリングリストに追加",
            .permissionsIntro: "Plumb がウィンドウの位置を制御するには以下の権限が必要です。",
            .accessibility: "アクセシビリティ",
            .screenRecording: "画面収録",
            .granted: "許可済み",
            .notGranted: "未許可",
            .openSettings: "設定を開く…",
            .launchAtLogin: "ログイン時に起動",
            .launchAtLoginHint: "Mac 起動時に Plumb を自動的に起動します。",
            .tabAbout: "について",
            .aboutVersion: "バージョン",
            .aboutGitHub: "GitHub",
            .aboutGitHubHint: "ソースコードの確認と問題の報告。",
            .aboutViewOnGitHub: "GitHub で見る",
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
            .otaCheckForUpdates: "更新を確認…",
            .otaUpToDate: "最新です。",
            .otaCheckFailed: "更新の確認に失敗しました。",
            .otaCheckFailedHint: "ネットワーク接続を確認して再試行してください。",
            .otaNewVersionTitle: "Plumb %@ が利用可能です",
            .otaUpdateNow: "今すぐ更新",
            .otaCancel: "キャンセル",
            .otaDownloadFailed: "ダウンロードに失敗しました。",
            .otaDownloadFailedHint: "パッケージが破損している可能性があります。後で再試行するか、GitHub から手動でダウンロードしてください。",
            .otaInstallingTitle: "更新をインストール中",
            .otaInstallingMessage: "Plumb を置き換えています…",
            .otaInstallDone: "完了。再起動中…",
            .otaInstallCanceled: "インストールがキャンセルされました。以前のバージョンを維持します。",
            .otaInstallFailed: "インストールに失敗しました。以前のバージョンを維持します。",
            .otaDownloadingTitle: "Plumb を更新中",
            .otaDownloadingMessage: "Plumb %@ をダウンロードしています…",
            .otaDownloadingSize: "%1$@ / %2$@",
            .otaDownloadCanceled: "ダウンロードがキャンセルされました。",
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
    static var bulkSelectAll: String { tr(.bulkSelectAll) }
    static var bulkDeselectAll: String { tr(.bulkDeselectAll) }
    static var enableAutoTiling: String { tr(.enableAutoTiling) }
    static var enableAutoTilingHint: String { tr(.enableAutoTilingHint) }
    static var margin: String { tr(.margin) }
    static var marginHint: String { tr(.marginHint) }
    static var tilingFootnoteOn: String { tr(.tilingFootnoteOn) }
    static var tilingFootnoteOff: String { tr(.tilingFootnoteOff) }
    static var documentChooserTitle: String { tr(.documentChooserTitle) }
    static var documentChooserFootnote: String { tr(.documentChooserFootnote) }
    static var documentChooserEmptyHint: String { tr(.documentChooserEmptyHint) }
    static var tilingSubtabAllowlist: String { tr(.tilingSubtabAllowlist) }
    static var tilingSubtabDocument: String { tr(.tilingSubtabDocument) }
    static var documentChooserDisabledHint: String { tr(.documentChooserDisabledHint) }
    static var permissionsIntro: String { tr(.permissionsIntro) }
    static var accessibility: String { tr(.accessibility) }
    static var screenRecording: String { tr(.screenRecording) }
    static var granted: String { tr(.granted) }
    static var notGranted: String { tr(.notGranted) }
    static var openSettings: String { tr(.openSettings) }
    static var launchAtLogin: String { tr(.launchAtLogin) }
    static var launchAtLoginHint: String { tr(.launchAtLoginHint) }
    static var tabAbout: String { tr(.tabAbout) }
    static var aboutVersion: String { tr(.aboutVersion) }
    static var aboutGitHub: String { tr(.aboutGitHub) }
    static var aboutGitHubHint: String { tr(.aboutGitHubHint) }
    static var aboutViewOnGitHub: String { tr(.aboutViewOnGitHub) }
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
    static var otaCheckForUpdates: String { tr(.otaCheckForUpdates) }
    static var otaUpToDate: String { tr(.otaUpToDate) }
    static var otaCheckFailed: String { tr(.otaCheckFailed) }
    static var otaCheckFailedHint: String { tr(.otaCheckFailedHint) }
    static var otaNewVersionTitle: String { tr(.otaNewVersionTitle) }
    static var otaUpdateNow: String { tr(.otaUpdateNow) }
    static var otaCancel: String { tr(.otaCancel) }
    static var otaDownloadFailed: String { tr(.otaDownloadFailed) }
    static var otaDownloadFailedHint: String { tr(.otaDownloadFailedHint) }
    static var otaInstallingTitle: String { tr(.otaInstallingTitle) }
    static var otaInstallingMessage: String { tr(.otaInstallingMessage) }
    static var otaInstallDone: String { tr(.otaInstallDone) }
    static var otaInstallCanceled: String { tr(.otaInstallCanceled) }
    static var otaInstallFailed: String { tr(.otaInstallFailed) }
    static var otaDownloadingTitle: String { tr(.otaDownloadingTitle) }
    static var otaDownloadingMessage: String { tr(.otaDownloadingMessage) }
    static var otaDownloadingSize: String { tr(.otaDownloadingSize) }
    static var otaDownloadCanceled: String { tr(.otaDownloadCanceled) }

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
