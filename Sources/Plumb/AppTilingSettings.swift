import CoreGraphics
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - TileInsets / AppTilingSettings / AppTilingSettingsStore
//
// 模块角色：平铺与居中的设置模型 + 持久化。
//
// TileInsets：平铺时窗口与屏幕四边（上/下/左/右）的独立间距。替代此前的单个统一
//   标量边距，全局与每个 App 都可独立设置上下左右间距；未单独设置 perAppInsets 的 App
//   回退全局 edgeInsets。
//
// 数据模型 AppTilingSettings：
//   - isEnabled / edgeInsets / tiledBundleIDs     ：平铺总开关、全局四向间距、平铺白名单。
//   - centerEnabled / centeredBundleIDs           ：居中总开关与居中白名单
//     （空列表 => 居中全部；非空 => 仅列表内；关闭 => 永不自动居中）。
//   - perAppInsets                                 ：每个 app 单独的上/下/左/右间距（key=归一化 bundle id）。
//   - documentChooserBundleIDs                    ：启用"文档选择器感知"的 App。
//     这些文档类 App（Pages/Word/Excel/Numbers 等）启动时常先弹出模板/文件列表窗口，
//     再打开真正的文档窗口。对其：选择器窗口只居中不平铺、且不锁 processedPIDs，
//     等真正的文档窗口（kAXDocument 非空）出现后才平铺。
//   - shouldTile / shouldCenter / isDocumentChooserApp：统一的判定语义，bundle id 做归一化（trim+小写）。
//
// 存储 AppTilingSettingsStore：
//   - 主存储为签名无关的文件 `~/Library/Application Support/Plumb/settings.json`，
//     文件路径仅取决于 bundle id 字符串，不依赖签名身份 → OTA 更新即使签名身份变化，
//     设置也不会丢失（cfprefsd 域会因签名身份漂移而失效，文件不会）。
//   - UserDefaults 作为镜像双写：保持向后兼容（旧版本/外部工具仍可读）。
//   - load()：优先读文件；文件缺失时读 UserDefaults 并一次性迁移写入文件；都缺则默认。
//   - save()：先写文件、再写 UserDefaults（双写）。
//
// 不变量：margin 在 [minimumEdgeMargin, maximumEdgeMargin] 内；bundle id 永远归一化存储。
// ─────────────────────────────────────────────────────────────────────────────

/// 平铺时窗口与屏幕四边的独立间距（上/下/左/右）。
///
/// 全局与每个 App 都用此四向模型：全局 `edgeInsets` 是默认间距，
/// perAppInsets 中未单独设置的 App 回退到全局 `edgeInsets`
///（见 `AppTilingSettings.effectiveInsets(for:)`）。
///
/// 坐标约定：`visibleFrame` 为左下原点坐标系（macOS NSScreen 约定），
/// `bottom` 加到 minY、`top` 从高度里扣（由 `WindowGeometry.tiledFrame` 处理）。
struct TileInsets: Codable, Equatable {
    var top: CGFloat
    var bottom: CGFloat
    var left: CGFloat
    var right: CGFloat

    static let zero = TileInsets(top: 0, bottom: 0, left: 0, right: 0)

    /// 四向统一构造（用于全局标量铺满 4 向、自检等）。
    init(top: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }

    /// 四向取同一值（全局统一边距 → 4 向 insets 的桥接）。
    init(all value: CGFloat) {
        self.init(top: value, bottom: value, left: value, right: value)
    }
}

/// 运行时自动排版的互斥决策（见 `AppTilingSettings.resolvedAutomaticLayout(for:)`）。
///
/// 平铺与自动居中在运行时互斥：一个 App 在同一激活周期内只会被自动「平铺」或「居中」之一，
/// 平铺优先（与 README「tiling has priority over auto-centering」一致）。显式决策类型替代了
/// 旧的隐式「先平铺再居中」行为，避免尺寸受限的平铺 App 被居中反复移动。
enum AutomaticLayoutMode: Equatable {
    case tile
    case center
    case none
}

struct AppTilingSettings: Equatable, Codable {
    static let defaultEdgeMargin: CGFloat = 16
    static let minimumEdgeMargin: CGFloat = 0
    static let maximumEdgeMargin: CGFloat = 400

    // 自定义 Codable：edgeInsets（后增四向字段，旧 settings.json 不含此键）与历史标量
    // edgeMargin / perAppMargins 都需用 decodeIfPresent 回退，否则旧文件解码会失败。
    //   - edgeInsets：全局四向间距；缺失 → 见下方迁移逻辑。
    //   - edgeMargin：旧全局标量；仅用于一次性迁移 → TileInsets(all:)。
    //   - perAppInsets：per-app 四向间距；缺失 → 见下方迁移逻辑。
    //   - perAppMargins：旧 per-app 标量；仅用于一次性迁移 → TileInsets(all:)。
    //   注意：历史标量键不进 CodingKeys（否则合成 Encodable 会因无对应存储属性而失败），
    //   仅在下面的 _LegacyKeys 单独声明，仅供 init(from:) 解码旧文件。
    private enum CodingKeys: String, CodingKey {
        case isEnabled, edgeInsets, tiledBundleIDs, hideSystemAppsInPicker
        case centerEnabled, centeredBundleIDs, documentChooserBundleIDs
        case perAppInsets, hideStatusBarIcon, autoCheckUpdates
    }

    /// 仅用于解码旧 settings.json 的历史标量键。不参与编码（已迁移至四向模型）。
    private enum _LegacyKeys: String, CodingKey {
        case edgeMargin, perAppMargins
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        // 全局四向间距：新键 edgeInsets；缺失时从历史标量 edgeMargin 一次性迁移。
        if let decoded = try c.decodeIfPresent(TileInsets.self, forKey: .edgeInsets) {
            edgeInsets = decoded
        } else {
            let legacyContainer = try decoder.container(keyedBy: _LegacyKeys.self)
            let legacyScalar = try legacyContainer.decodeIfPresent(CGFloat.self, forKey: .edgeMargin) ?? Self.defaultEdgeMargin
            edgeInsets = TileInsets(all: legacyScalar)
        }
        tiledBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .tiledBundleIDs) ?? []
        hideSystemAppsInPicker = try c.decodeIfPresent(Bool.self, forKey: .hideSystemAppsInPicker) ?? true
        centerEnabled = try c.decodeIfPresent(Bool.self, forKey: .centerEnabled) ?? true
        centeredBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .centeredBundleIDs) ?? []
        documentChooserBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .documentChooserBundleIDs) ?? Self.defaultDocumentChooserBundleIDs
        // 旧文件迁移必须按“键是否缺失”判断，而不是按新映射是否为空判断。显式空映射
        // 表示用户已经清除了所有 per-app override；若此时再读残留的 perAppMargins，
        // 被删除的旧设置会在下一次启动复活。
        if let decoded = try c.decodeIfPresent([String: TileInsets].self, forKey: .perAppInsets) {
            perAppInsets = decoded
        } else {
            let legacyContainer = try decoder.container(keyedBy: _LegacyKeys.self)
            let legacy = try legacyContainer.decodeIfPresent([String: CGFloat].self, forKey: .perAppMargins) ?? [:]
            perAppInsets = Dictionary(uniqueKeysWithValues: legacy.map { (k, v) in
                (Self.normalizeBundleID(k), TileInsets(all: v))
            }.filter { !$0.0.isEmpty })
        }
        // 后增字段：旧 settings.json 不含此键 → 回退 false（默认显示图标，保持既有行为）。
        hideStatusBarIcon = try c.decodeIfPresent(Bool.self, forKey: .hideStatusBarIcon) ?? false
        // 后增字段：旧 settings.json 不含此键 → 回退 true（默认开启自动检查，保持既有行为）。
        // 控制「自动」更新检查（启动、后台定期、打开设置）；手动检查（菜单项/关于页按钮）不受限。
        autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
    }

    /// 显式成员初始化器。自定义了 init(from:) 后编译器不再合成默认成员初始化器，
    /// 故在此显式提供，供 .default、normalized()、持久化层、测试构造使用。
    init(
        isEnabled: Bool,
        edgeInsets: TileInsets,
        tiledBundleIDs: Set<String>,
        hideSystemAppsInPicker: Bool,
        centerEnabled: Bool,
        centeredBundleIDs: Set<String>,
        documentChooserBundleIDs: Set<String>,
        perAppInsets: [String: TileInsets] = [:],
        hideStatusBarIcon: Bool = false,
        autoCheckUpdates: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.edgeInsets = edgeInsets
        self.tiledBundleIDs = tiledBundleIDs
        self.hideSystemAppsInPicker = hideSystemAppsInPicker
        self.centerEnabled = centerEnabled
        self.centeredBundleIDs = centeredBundleIDs
        self.documentChooserBundleIDs = documentChooserBundleIDs
        self.perAppInsets = perAppInsets
        self.hideStatusBarIcon = hideStatusBarIcon
        self.autoCheckUpdates = autoCheckUpdates
    }

    /// 默认启用"文档选择器感知"的 App 集合。
    ///
    /// 这些 App 启动时通常先弹出模板/文件列表窗口（如 Word 的"打开新的和最近使用的文件"），
    /// 再打开真正的文档窗口。实测确认（2026-06，macOS 26）：
    ///   - 选择器窗口与文档窗口的 subrole 都是 AXStandardWindow（仅凭 subrole 无法区分）；
    ///   - 选择器窗口的 kAXDocumentAttribute 为空，文档窗口为 file:// URL；
    /// 故用 kAXDocument 是否非空区分两者，对选择器只居中、不平铺、不锁 PID，
    /// 等文档窗口出现后再平铺。
    ///
    /// ⚠️ Pages/Numbers 的 bundle id 在不同 macOS 版本上大小写不同：旧版为
    /// `com.apple.iwork.pages/numbers`，当前 macOS 上实际为 `com.apple.Pages/Numbers`
    ///（归一化后 `com.apple.pages/numbers`）。两类都需保留，否则新版 Pages/Numbers
    /// 不会命中选择器感知，导致模板/文件列表被当作普通窗口平铺。
    static let defaultDocumentChooserBundleIDs: Set<String> = [
        "com.apple.iwork.pages",      // Pages（旧 bundle id）
        "com.apple.iwork.numbers",    // Numbers（旧 bundle id）
        "com.apple.pages",            // Pages（当前 macOS 实际 bundle id，归一化后小写）
        "com.apple.numbers",          // Numbers（当前 macOS 实际 bundle id）
        "com.microsoft.word",         // Microsoft Word
        "com.microsoft.excel"         // Microsoft Excel
    ]

    var isEnabled: Bool
    /// 全局默认四向间距。未单独设置 perAppInsets 的 app 回退到此项。
    var edgeInsets: TileInsets
    var tiledBundleIDs: Set<String>
    var hideSystemAppsInPicker: Bool

    /// 是否隐藏菜单栏水滴图标（默认 false = 显示，保持既有行为）。
    /// 隐藏后无菜单栏入口，设置界面只能通过「连续两次打开 Plumb」的逃生口重新进入
    ///（详见 AppDelegate.applicationShouldHandleReopen）。
    var hideStatusBarIcon: Bool

    /// 是否自动检查更新（默认 true = 开启，保持既有行为）。
    /// 控制所有「自动」检查路径：启动检查、后台定期检查、打开设置时的检查。
    /// 关闭时这些路径全部跳过；手动检查（菜单栏「检查更新…」与关于页按钮）不受此开关限制。
    var autoCheckUpdates: Bool

    /// 居中功能总开关（默认开启，保持既有行为）。
    var centerEnabled: Bool
    /// 仅对列表内 app 自动居中；为空时居中全部 app（向后兼容）。
    var centeredBundleIDs: Set<String>

    /// 启用"文档选择器感知"的 App（默认预置 Pages/Numbers/Word/Excel）。
    /// 语义：仅影响选择器窗口的处理方式，**不影响**该 App 是否会被平铺——后者仍由
    /// `tiledBundleIDs` 决定。即一个 App 必须同时在 `tiledBundleIDs` 内才会被平铺。
    var documentChooserBundleIDs: Set<String>

    /// 每个 app 单独的平铺四向间距（key = 归一化 bundle id）。
    /// key 不存在或 bundle id 为 nil → 回退全局 `edgeInsets`（满足"没单独设置用默认"）。
    /// value 各方向经 `normalized()` 钳制到 `[minimumEdgeMargin, maximumEdgeMargin]`，key 归一化存储。
    var perAppInsets: [String: TileInsets]

    static let `default` = AppTilingSettings(
        isEnabled: false,
        edgeInsets: TileInsets(all: defaultEdgeMargin),
        tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: defaultDocumentChooserBundleIDs,
        perAppInsets: [:]
    )

    func normalized() -> AppTilingSettings {
        let normalizedTileIDs = Set(tiledBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        let normalizedCenterIDs = Set(centeredBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        let normalizedChooserIDs = Set(documentChooserBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        // 全局四向间距：逐方向钳制到合法范围。
        let normalizedEdge = TileInsets(
            top: clamp(edgeInsets.top, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin),
            bottom: clamp(edgeInsets.bottom, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin),
            left: clamp(edgeInsets.left, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin),
            right: clamp(edgeInsets.right, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin)
        )
        // per-app 间距：key 归一化、空 key 剔除、value 四向各自钳制到合法范围。
        var normalizedPerApp: [String: TileInsets] = [:]
        for (rawKey, rawInsets) in perAppInsets {
            let key = Self.normalizeBundleID(rawKey)
            guard !key.isEmpty else { continue }
            normalizedPerApp[key] = TileInsets(
                top: clamp(rawInsets.top, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin),
                bottom: clamp(rawInsets.bottom, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin),
                left: clamp(rawInsets.left, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin),
                right: clamp(rawInsets.right, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin)
            )
        }
        return AppTilingSettings(
            isEnabled: isEnabled,
            edgeInsets: normalizedEdge,
            tiledBundleIDs: normalizedTileIDs,
            hideSystemAppsInPicker: hideSystemAppsInPicker,
            centerEnabled: centerEnabled,
            centeredBundleIDs: normalizedCenterIDs,
            documentChooserBundleIDs: normalizedChooserIDs,
            perAppInsets: normalizedPerApp,
            hideStatusBarIcon: hideStatusBarIcon,
            autoCheckUpdates: autoCheckUpdates
        )
    }

    /// 该 app 平铺时使用的有效四向间距。
    /// - bundle id 不在 `perAppInsets`（或为 nil、归一化后为空）→ 回退全局 `edgeInsets`；
    /// - 否则返回该 app 的自定义四向间距（已归一化、钳制）。
    /// 这是 per-app 平铺间距的核心解析入口，满足"没单独设置用默认"语义。
    func effectiveInsets(for bundleIdentifier: String?) -> TileInsets {
        let normalized = bundleIdentifier.map(Self.normalizeBundleID) ?? ""
        if !normalized.isEmpty, let custom = perAppInsets[normalized] {
            return custom
        }
        return edgeInsets
    }

    func shouldTile(bundleIdentifier: String?) -> Bool {
        guard isEnabled else { return false }
        guard let bundleIdentifier else { return false }
        return tiledBundleIDs.contains(Self.normalizeBundleID(bundleIdentifier))
    }

    /// 是否应自动居中。列表为空 => 全部居中；非空 => 仅列表内；关闭 => 永不自动居中。
    /// 注意：手动"立即居中"不由此方法控制，始终可用。
    func shouldCenter(bundleIdentifier: String?) -> Bool {
        guard centerEnabled else { return false }
        if centeredBundleIDs.isEmpty { return true }
        guard let bundleIdentifier else { return false }
        return centeredBundleIDs.contains(Self.normalizeBundleID(bundleIdentifier))
    }

    /// 运行时自动排版的互斥决策（平铺 / 居中 / 不动）。
    ///
    /// 这是唯一真源：一个 App 在运行时只会被自动「平铺」或「居中」之一，不会同时两者。
    /// 平铺与自动居中互斥，平铺优先（与 README「For allowlisted apps, tiling has priority
    /// over auto-centering」一致）。一个设置文件里同一个 bundle id 合法地同时出现在
    /// `tiledBundleIDs` 与 `centeredBundleIDs` 是允许的（历史/用户选择），本方法在运行时
    /// 确定性地解析为 `.tile`——不修改用户的设置。
    ///
    /// 显式决策类型替代了旧的隐式「先平铺再居中」（centerAfterTile）行为：后者让一个尺寸受限、
    /// 拒绝目标高度的平铺 App 在每次激活时都被居中再次移动，造成「反复上下跳动」的回归。
    func resolvedAutomaticLayout(for bundleIdentifier: String?) -> AutomaticLayoutMode {
        // 平铺优先：命中即返回 .tile，不再评估居中。
        if shouldTile(bundleIdentifier: bundleIdentifier) { return .tile }
        if shouldCenter(bundleIdentifier: bundleIdentifier) { return .center }
        return .none
    }

    /// 是否启用"文档选择器感知"（仅对这些 App 的选择器窗口做特殊处理）。
    /// bundle id 归一化后匹配。
    func isDocumentChooserApp(bundleIdentifier: String?) -> Bool {
        guard !documentChooserBundleIDs.isEmpty, let bundleIdentifier else { return false }
        return documentChooserBundleIDs.contains(Self.normalizeBundleID(bundleIdentifier))
    }

    /// 三个 app 列表与 per-app 映射是否全部为空（测试与设置状态展示辅助）。
    var allListsEmpty: Bool {
        tiledBundleIDs.isEmpty && centeredBundleIDs.isEmpty && documentChooserBundleIDs.isEmpty && perAppInsets.isEmpty
    }

    static func normalizeBundleID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func clamp(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        Swift.max(lowerBound, Swift.min(value, upperBound))
    }
}

final class AppTilingSettingsStore {
    private enum Keys {
        static let enabled = "tiling.enabled"
        static let edgeInsets = "tiling.edgeInsets"
        static let bundleIDs = "tiling.bundleIDs"
        static let hideSystemApps = "tiling.hideSystemAppsInPicker"
        static let centerEnabled = "centering.enabled"
        static let centeredBundleIDs = "centering.bundleIDs"
        static let documentChooserBundleIDs = "tiling.documentChooserBundleIDs"
        static let perAppInsets = "tiling.perAppInsets"
        static let legacyEdgeMargin = "tiling.edgeMargin"        // 仅读取用于一次性迁移
        static let legacyPerAppMargins = "tiling.perAppMargins"   // 仅读取用于一次性迁移
        static let hideStatusBarIcon = "appearance.hideStatusBarIcon"
        static let autoCheckUpdates = "updates.autoCheckUpdates"
    }

    private let defaults: UserDefaults
    /// 签名无关的设置文件。默认指向 `~/Library/Application Support/Plumb/settings.json`，
    /// 仅取决于 bundle id 字符串，不依赖签名身份 → OTA 更新后设置不会丢失。
    /// 测试可注入临时路径。
    private let settingsFileURL: URL
    /// Injectable atomic writer for deterministic failure-path tests. Production uses
    /// `Data.write(options: .atomic)`.
    private let fileWriter: (Data, URL) throws -> Void

    /// 内存缓存：避免窗口事件热路径每次都同步读 settings.json。
    /// store 本身不是 @MainActor（设置 UI、Observer、AppDelegate 都可能从主线程访问），
    /// 但读路径必须线程安全——用 NSLock 保护。
    /// 语义：nil 表示尚未加载（首次 load 会落盘读取并回填）；save() 写盘后同步更新为最新值。
    /// 新 store 实例缓存为 nil，仍从文件/Defaults 读取，保证重启/OTA 持久化测试成立。
    private var cachedSettings: AppTilingSettings?
    private let cacheLock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        settingsFileURL: URL? = nil,
        fileWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) {
        self.defaults = defaults
        self.fileWriter = fileWriter
        if let settingsFileURL {
            self.settingsFileURL = settingsFileURL
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let dir = appSupport.appendingPathComponent("Plumb", isDirectory: true)
            // 确保目录存在（幂等）。
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                DiagnosticLog.debug("SettingsStore: init createDirectory FAILED at \(dir.path): \(error)")
            }
            self.settingsFileURL = dir.appendingPathComponent("settings.json")
        }
        // 记录解析出的文件路径，便于排查「路径不一致导致更新后读不到」。
        DiagnosticLog.debug("SettingsStore: init fileURL=\(self.settingsFileURL.path) exists=\(FileManager.default.fileExists(atPath: self.settingsFileURL.path))")
    }

    func load() -> AppTilingSettings {
        // Serialize the first disk load with save(). Without holding ownership across IO,
        // a slow initial load can read the old file, race a successful save, and overwrite
        // the new in-memory cache after that save completes.
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedSettings {
            return cached
        }
        let settings = loadUncached()
        cachedSettings = settings
        return settings
    }

    /// 不经过缓存的落盘读取（可解码文件绝对权威；文件失败时 UserDefaults 降级；仅缺失时迁移）。
    private func loadUncached() -> AppTilingSettings {
        // 1) 优先读文件（签名无关、跨更新稳定）。
        // 只要文件可解码，它就是权威值；不再用 UserDefaults 的列表数量反向覆盖。
        //
        // 原来的“镜像条目更多就修复文件”有一个致命反例：UserDefaults 域在签名
        // 变化/重置后可能完全为空，loadFromUserDefaults() 此时返回 `.default`；而默认值
        // 自带 6 个 documentChooserBundleIDs。一份合法但列表少于 6 项的 settings.json 会因此被
        // 误判为“更空”，整份配置（包括所有标量开关）被默认值覆盖。这恰好破坏了
        // 设置文件用于抵御签名域漂移的核心目标。
        //
        // 文件损坏/不可读时仍可按仓库契约用 UserDefaults 做本次运行的降级恢复，但不得把镜像
        // 回写覆盖损坏文件；只有文件确实缺失时才允许一次性迁移。未来若需双向修复，必须为
        // 两份数据增加显式 generation/revision，不能再从条目数推断新旧。
        let fileExists = FileManager.default.fileExists(atPath: settingsFileURL.path)
        if let fileSettings = readFromFile() {
            DiagnosticLog.debug("SettingsStore: load ← FILE ok \(summary(fileSettings))")
            return fileSettings
        }

        // 2) 文件缺失/损坏/不可读 → 读 UserDefaults 作为降级。
        let userDefaultsSettings = loadFromUserDefaults()
        DiagnosticLog.debug("SettingsStore: load ← UserDefaults (file \(fileExists ? "unreadable/corrupt" : "missing")) \(summary(userDefaultsSettings))")

        // 3) 一次性迁移仅限文件不存在：UserDefaults 有非默认数据时写入文件，之后文件为准。
        //    文件存在但损坏时保留原文件供诊断，绝不把可能陈旧的镜像反向覆盖进去。
        //    （UserDefaults 全空 → 返回的就是 .default，不写文件，保持首次启动干净。）
        if !fileExists, userDefaultsSettings != .default {
            DiagnosticLog.debug("SettingsStore: load migrating UserDefaults → file")
            writeToFile(userDefaultsSettings)
        } else if fileExists {
            DiagnosticLog.debug("SettingsStore: load preserving unreadable/corrupt file; no reverse migration")
        } else {
            DiagnosticLog.debug("SettingsStore: load UserDefaults==.default, no migration")
        }
        return userDefaultsSettings
    }

    /// 设置摘要（用于日志，不含敏感数据，仅计数+开关）。
    func summary(forLog s: AppTilingSettings) -> String {
            "enabled=\(s.isEnabled) centerEnabled=\(s.centerEnabled) insets=t\(Int(s.edgeInsets.top))b\(Int(s.edgeInsets.bottom))l\(Int(s.edgeInsets.left))r\(Int(s.edgeInsets.right)) tiled=\(s.tiledBundleIDs.count) centered=\(s.centeredBundleIDs.count) chooser=\(s.documentChooserBundleIDs.count) perAppInsets=\(s.perAppInsets.count) hideIcon=\(s.hideStatusBarIcon) autoCheck=\(s.autoCheckUpdates)"
    }

    private func summary(_ s: AppTilingSettings) -> String {
        summary(forLog: s)
    }

    @discardableResult
    func save(_ settings: AppTilingSettings) -> Bool {
        // One store instance has a single ordered persistence stream. This also prevents
        // concurrent menu/UI saves from publishing a stale cache over a newer write.
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let normalized = settings.normalized()
        DiagnosticLog.debug("SettingsStore: save called \(summary(normalized))")
        // 先写文件（主存储），再写 UserDefaults（镜像，向后兼容）。
        // 主文件写失败时，若旧文件仍可解码，它仍是权威值；镜像也必须保持该旧值，
        // 否则主文件日后丢失/损坏时，刚被拒绝的设置会从 UserDefaults 重新复活。
        // 只有不存在可解码主文件时，才把本次值作为唯一可恢复的降级副本。
        let primaryWriteSucceeded = writeToFile(normalized)

        // A still-decodable old primary file remains authoritative after a failed write.
        // Do not cache the unsaved value and pretend it persisted; menu/UI callers can use
        // the returned false to revert. If no valid primary exists, the mirrored value is the
        // only recoverable copy and remains the runtime fallback.
        let cachedValue: AppTilingSettings
        if primaryWriteSucceeded {
            cachedValue = normalized
        } else if let persisted = readFromFile() {
            cachedValue = persisted
        } else {
            cachedValue = normalized
        }
        saveToUserDefaults(cachedValue)
        cachedSettings = cachedValue
        return primaryWriteSucceeded
    }

    // MARK: - File persistence（主存储，签名无关）

    private func readFromFile() -> AppTilingSettings? {
        let path = settingsFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            DiagnosticLog.debug("SettingsStore: readFromFile — file does not exist at \(path)")
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: settingsFileURL)
        } catch {
            DiagnosticLog.debug("SettingsStore: readFromFile — Data() FAILED at \(path): \(error)")
            return nil
        }
        do {
            let decoded = try JSONDecoder().decode(AppTilingSettings.self, from: data)
            DiagnosticLog.debug("SettingsStore: readFromFile — decoded ok from \(path) \(summary(decoded))")
            return decoded
        } catch {
            DiagnosticLog.debug("SettingsStore: readFromFile — JSON decode FAILED at \(path): \(error) rawSize=\(data.count)")
            return nil
        }
    }

    @discardableResult
    private func writeToFile(_ settings: AppTilingSettings) -> Bool {
        let path = settingsFileURL.path
        let data: Data
        do {
            data = try JSONEncoder().encode(settings)
        } catch {
            DiagnosticLog.debug("SettingsStore: writeToFile — JSON encode FAILED: \(error)")
            return false
        }
        let dir = settingsFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            DiagnosticLog.debug("SettingsStore: writeToFile — createDirectory FAILED at \(dir.path): \(error)")
            return false
        }
        // 原子写：避免写入中途崩溃导致文件损坏。
        do {
            try fileWriter(data, settingsFileURL)
            DiagnosticLog.debug("SettingsStore: writeToFile — wrote \(data.count) bytes to \(path)")
            return true
        } catch {
            DiagnosticLog.debug("SettingsStore: writeToFile — data.write FAILED at \(path): \(error)")
            return false
        }
    }

    // MARK: - UserDefaults（镜像，向后兼容）

    private func loadFromUserDefaults() -> AppTilingSettings {
        let hasEnabled = defaults.object(forKey: Keys.enabled) != nil
        let hasEdgeInsets = defaults.object(forKey: Keys.edgeInsets) != nil
        let hasLegacyEdgeMargin = defaults.object(forKey: Keys.legacyEdgeMargin) != nil
        let hasBundleIDs = defaults.object(forKey: Keys.bundleIDs) != nil
        let hasHideSystemApps = defaults.object(forKey: Keys.hideSystemApps) != nil
        let hasCenterEnabled = defaults.object(forKey: Keys.centerEnabled) != nil
        let hasCenteredBundleIDs = defaults.object(forKey: Keys.centeredBundleIDs) != nil
        let hasDocumentChooserBundleIDs = defaults.object(forKey: Keys.documentChooserBundleIDs) != nil
        let hasPerAppInsets = defaults.object(forKey: Keys.perAppInsets) != nil
        let hasLegacyPerAppMargins = defaults.object(forKey: Keys.legacyPerAppMargins) != nil
        let hasHideStatusBarIcon = defaults.object(forKey: Keys.hideStatusBarIcon) != nil
        let hasAutoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) != nil

        if !hasEnabled, !hasEdgeInsets, !hasLegacyEdgeMargin, !hasBundleIDs, !hasHideSystemApps,
           !hasCenterEnabled, !hasCenteredBundleIDs, !hasDocumentChooserBundleIDs,
           !hasPerAppInsets, !hasLegacyPerAppMargins, !hasHideStatusBarIcon,
           !hasAutoCheckUpdates {
            return .default
        }

        let isEnabled = hasEnabled ? defaults.bool(forKey: Keys.enabled) : AppTilingSettings.default.isEnabled
        // 全局四向间距：新键 edgeInsets（[String: Double] 的 top/bottom/left/right）；
        // 缺失时从历史标量 edgeMargin 一次性迁移 → TileInsets(all:)。
        var edgeInsets: TileInsets
        if let dirs = defaults.dictionary(forKey: Keys.edgeInsets) as? [String: Double] {
            edgeInsets = TileInsets(
                top: CGFloat(dirs["top"] ?? 0),
                bottom: CGFloat(dirs["bottom"] ?? 0),
                left: CGFloat(dirs["left"] ?? 0),
                right: CGFloat(dirs["right"] ?? 0)
            )
        } else if hasLegacyEdgeMargin {
            edgeInsets = TileInsets(all: CGFloat(defaults.double(forKey: Keys.legacyEdgeMargin)))
        } else {
            edgeInsets = AppTilingSettings.default.edgeInsets
        }
        let bundleIDsArray = defaults.array(forKey: Keys.bundleIDs) as? [String] ?? []
        let hideSystemApps = hasHideSystemApps ? defaults.bool(forKey: Keys.hideSystemApps) : AppTilingSettings.default.hideSystemAppsInPicker
        let centerEnabled = hasCenterEnabled ? defaults.bool(forKey: Keys.centerEnabled) : AppTilingSettings.default.centerEnabled
        let centeredBundleIDsArray = defaults.array(forKey: Keys.centeredBundleIDs) as? [String] ?? []
        // 向后兼容：旧版本无此键时回退到默认预置的 4 个文档类 App。
        let documentChooserBundleIDsArray = hasDocumentChooserBundleIDs
            ? (defaults.array(forKey: Keys.documentChooserBundleIDs) as? [String] ?? [])
            : Array(AppTilingSettings.default.documentChooserBundleIDs)
        // per-app 四向间距：UserDefaults 存为 [String: [String: Double]]（每项 top/bottom/left/right）。
        var perAppInsets: [String: TileInsets] = [:]
        if let insetsRaw = defaults.dictionary(forKey: Keys.perAppInsets) as? [String: [String: Double]] {
            for (k, dirs) in insetsRaw {
                let key = AppTilingSettings.normalizeBundleID(k)
                guard !key.isEmpty else { continue }
                perAppInsets[key] = TileInsets(
                    top: CGFloat(dirs["top"] ?? 0),
                    bottom: CGFloat(dirs["bottom"] ?? 0),
                    left: CGFloat(dirs["left"] ?? 0),
                    right: CGFloat(dirs["right"] ?? 0)
                )
            }
        }
        // 旧键迁移：perAppInsets 缺失但历史标量 perAppMargins 存在 → 每个标量转 TileInsets(all:)。
        if !hasPerAppInsets,
           let legacyRaw = defaults.dictionary(forKey: Keys.legacyPerAppMargins) as? [String: Double] {
            for (k, v) in legacyRaw {
                let key = AppTilingSettings.normalizeBundleID(k)
                guard !key.isEmpty else { continue }
                perAppInsets[key] = TileInsets(all: CGFloat(v))
            }
        }
        let hideStatusBarIcon = hasHideStatusBarIcon
            ? defaults.bool(forKey: Keys.hideStatusBarIcon)
            : AppTilingSettings.default.hideStatusBarIcon
        let autoCheckUpdates = hasAutoCheckUpdates
            ? defaults.bool(forKey: Keys.autoCheckUpdates)
            : AppTilingSettings.default.autoCheckUpdates

        return AppTilingSettings(
            isEnabled: isEnabled,
            edgeInsets: edgeInsets,
            tiledBundleIDs: Set(bundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty }),
            hideSystemAppsInPicker: hideSystemApps,
            centerEnabled: centerEnabled,
            centeredBundleIDs: Set(centeredBundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty }),
            documentChooserBundleIDs: Set(documentChooserBundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty }),
            perAppInsets: perAppInsets,
            hideStatusBarIcon: hideStatusBarIcon,
            autoCheckUpdates: autoCheckUpdates
        ).normalized()
    }

    private func saveToUserDefaults(_ normalized: AppTilingSettings) {
        defaults.set(normalized.isEnabled, forKey: Keys.enabled)
        // 全局四向间距镜像双写：[String: Double]（top/bottom/left/right）。
        // 不再双写旧键 tiling.edgeMargin（仅读取迁移用）——首次 save 后旧键即被新键取代。
        let edgeDict: [String: Double] = [
            "top": Double(normalized.edgeInsets.top),
            "bottom": Double(normalized.edgeInsets.bottom),
            "left": Double(normalized.edgeInsets.left),
            "right": Double(normalized.edgeInsets.right)
        ]
        defaults.set(edgeDict, forKey: Keys.edgeInsets)
        defaults.set(Array(normalized.tiledBundleIDs).sorted(), forKey: Keys.bundleIDs)
        defaults.set(normalized.hideSystemAppsInPicker, forKey: Keys.hideSystemApps)
        defaults.set(normalized.centerEnabled, forKey: Keys.centerEnabled)
        defaults.set(Array(normalized.centeredBundleIDs).sorted(), forKey: Keys.centeredBundleIDs)
        defaults.set(Array(normalized.documentChooserBundleIDs).sorted(), forKey: Keys.documentChooserBundleIDs)
        // per-app 四向间距镜像双写：序列化为 [String: [String: Double]]（UserDefaults 原生支持）。
        // 不再双写旧键 tiling.perAppMargins（仅读取迁移用）——首次 save 后旧键即被新键取代。
        let perAppDict = Dictionary(uniqueKeysWithValues: normalized.perAppInsets.map { (k, insets) in
            (k, ["top": Double(insets.top), "bottom": Double(insets.bottom),
                 "left": Double(insets.left), "right": Double(insets.right)] as [String: Double])
        })
        defaults.set(perAppDict, forKey: Keys.perAppInsets)
        defaults.set(normalized.hideStatusBarIcon, forKey: Keys.hideStatusBarIcon)
        defaults.set(normalized.autoCheckUpdates, forKey: Keys.autoCheckUpdates)
        // 新键一旦写入（即使是显式空映射）就代表迁移已经完成。必须删除旧键；否则
        // settings.json 丢失/损坏而降级读 UserDefaults 时，旧 per-app override 会复活。
        defaults.removeObject(forKey: Keys.legacyEdgeMargin)
        defaults.removeObject(forKey: Keys.legacyPerAppMargins)
    }
}
