import CoreGraphics
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppTilingSettings / AppTilingSettingsStore
//
// 模块角色：平铺与居中的设置模型 + 持久化。
//
// 数据模型 AppTilingSettings：
//   - isEnabled / edgeMargin / tiledBundleIDs     ：平铺总开关、四边距、平铺白名单。
//   - centerEnabled / centeredBundleIDs           ：居中总开关与居中白名单
//     （空列表 => 居中全部；非空 => 仅列表内；关闭 => 永不自动居中）。
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

struct AppTilingSettings: Equatable, Codable {
    static let defaultEdgeMargin: CGFloat = 16
    static let minimumEdgeMargin: CGFloat = 0
    static let maximumEdgeMargin: CGFloat = 400

    // 自定义 Codable：perAppMargins 是后增字段，旧 settings.json 不含此键 →
    // 自动合成的 init(from:) 会解码失败。这里用 decodeIfPresent 回退到空字典，
    // 保证向后兼容（老版本 settings 全部走默认边距）。
    private enum CodingKeys: String, CodingKey {
        case isEnabled, edgeMargin, tiledBundleIDs, hideSystemAppsInPicker
        case centerEnabled, centeredBundleIDs, documentChooserBundleIDs
        case perAppMargins
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        edgeMargin = try c.decodeIfPresent(CGFloat.self, forKey: .edgeMargin) ?? Self.defaultEdgeMargin
        tiledBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .tiledBundleIDs) ?? []
        hideSystemAppsInPicker = try c.decodeIfPresent(Bool.self, forKey: .hideSystemAppsInPicker) ?? true
        centerEnabled = try c.decodeIfPresent(Bool.self, forKey: .centerEnabled) ?? true
        centeredBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .centeredBundleIDs) ?? []
        documentChooserBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .documentChooserBundleIDs) ?? Self.defaultDocumentChooserBundleIDs
        perAppMargins = try c.decodeIfPresent([String: CGFloat].self, forKey: .perAppMargins) ?? [:]
    }

    /// 显式成员初始化器。自定义了 init(from:) 后编译器不再合成默认成员初始化器，
    /// 故在此显式提供，供 .default、normalized()、持久化层、测试构造使用。
    init(
        isEnabled: Bool,
        edgeMargin: CGFloat,
        tiledBundleIDs: Set<String>,
        hideSystemAppsInPicker: Bool,
        centerEnabled: Bool,
        centeredBundleIDs: Set<String>,
        documentChooserBundleIDs: Set<String>,
        perAppMargins: [String: CGFloat] = [:]
    ) {
        self.isEnabled = isEnabled
        self.edgeMargin = edgeMargin
        self.tiledBundleIDs = tiledBundleIDs
        self.hideSystemAppsInPicker = hideSystemAppsInPicker
        self.centerEnabled = centerEnabled
        self.centeredBundleIDs = centeredBundleIDs
        self.documentChooserBundleIDs = documentChooserBundleIDs
        self.perAppMargins = perAppMargins
    }

    /// 默认启用"文档选择器感知"的 App 集合。
    ///
    /// 这些 App 启动时通常先弹出模板/文件列表窗口（如 Word 的"打开新的和最近使用的文件"），
    /// 再打开真正的文档窗口。实测确认（2026-06，macOS 26）：
    ///   - 选择器窗口与文档窗口的 subrole 都是 AXStandardWindow（仅凭 subrole 无法区分）；
    ///   - 选择器窗口的 kAXDocumentAttribute 为空，文档窗口为 file:// URL；
    /// 故用 kAXDocument 是否非空区分两者，对选择器只居中、不平铺、不锁 PID，
    /// 等文档窗口出现后再平铺。
    static let defaultDocumentChooserBundleIDs: Set<String> = [
        "com.apple.iwork.pages",      // Pages
        "com.apple.iwork.numbers",    // Numbers
        "com.microsoft.word",         // Microsoft Word
        "com.microsoft.excel"         // Microsoft Excel
    ]

    var isEnabled: Bool
    var edgeMargin: CGFloat
    var tiledBundleIDs: Set<String>
    var hideSystemAppsInPicker: Bool

    /// 居中功能总开关（默认开启，保持既有行为）。
    var centerEnabled: Bool
    /// 仅对列表内 app 自动居中；为空时居中全部 app（向后兼容）。
    var centeredBundleIDs: Set<String>

    /// 启用"文档选择器感知"的 App（默认预置 Pages/Numbers/Word/Excel）。
    /// 语义：仅影响选择器窗口的处理方式，**不影响**该 App 是否会被平铺——后者仍由
    /// `tiledBundleIDs` 决定。即一个 App 必须同时在 `tiledBundleIDs` 内才会被平铺。
    var documentChooserBundleIDs: Set<String>

    /// 每个 app 单独的平铺边距（key = 归一化 bundle id）。
    /// key 不存在或 bundle id 为 nil → 回退全局 `edgeMargin`（满足"没单独设置用默认"）。
    /// value 经 `normalized()` 钳制到 `[minimumEdgeMargin, maximumEdgeMargin]`，key 归一化存储。
    var perAppMargins: [String: CGFloat]

    static let `default` = AppTilingSettings(
        isEnabled: false,
        edgeMargin: defaultEdgeMargin,
        tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: defaultDocumentChooserBundleIDs,
        perAppMargins: [:]
    )

    func normalized() -> AppTilingSettings {
        let normalizedTileIDs = Set(tiledBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        let normalizedCenterIDs = Set(centeredBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        let normalizedChooserIDs = Set(documentChooserBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        let normalizedMargin = clamp(edgeMargin, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin)
        // per-app 边距：key 归一化、空 key 剔除、value 钳制到合法范围。
        var normalizedPerApp: [String: CGFloat] = [:]
        for (rawKey, rawValue) in perAppMargins {
            let key = Self.normalizeBundleID(rawKey)
            guard !key.isEmpty else { continue }
            normalizedPerApp[key] = clamp(rawValue, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin)
        }
        return AppTilingSettings(
            isEnabled: isEnabled,
            edgeMargin: normalizedMargin,
            tiledBundleIDs: normalizedTileIDs,
            hideSystemAppsInPicker: hideSystemAppsInPicker,
            centerEnabled: centerEnabled,
            centeredBundleIDs: normalizedCenterIDs,
            documentChooserBundleIDs: normalizedChooserIDs,
            perAppMargins: normalizedPerApp
        )
    }

    /// 该 app 平铺时使用的有效边距。
    /// - bundle id 不在 `perAppMargins`（或为 nil、归一化后为空）→ 回退全局 `edgeMargin`；
    /// - 否则返回该 app 的自定义边距（已归一化、钳制）。
    /// 这是 per-app 平铺边距的核心解析入口，满足"没单独设置用默认"语义。
    func effectiveMargin(for bundleIdentifier: String?) -> CGFloat {
        let normalized = bundleIdentifier.map(Self.normalizeBundleID) ?? ""
        if !normalized.isEmpty, let custom = perAppMargins[normalized] {
            return custom
        }
        return edgeMargin
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

    /// 是否启用"文档选择器感知"（仅对这些 App 的选择器窗口做特殊处理）。
    /// bundle id 归一化后匹配。
    func isDocumentChooserApp(bundleIdentifier: String?) -> Bool {
        guard !documentChooserBundleIDs.isEmpty, let bundleIdentifier else { return false }
        return documentChooserBundleIDs.contains(Self.normalizeBundleID(bundleIdentifier))
    }

    /// 三个 app 列表是否全部为空。用于 load() 一致性守卫：文件被异常清空时三个列表通常同时变空。
    /// perAppMargins（app→值映射）的条目计数也纳入判断，保持"文件被清空时各映射同时变空"的守卫语义。
    var allListsEmpty: Bool {
        tiledBundleIDs.isEmpty && centeredBundleIDs.isEmpty && documentChooserBundleIDs.isEmpty && perAppMargins.isEmpty
    }

    /// 当前设置的列表是否"严格少于"另一份设置。
    /// 用于一致性守卫：当文件全空、而 UserDefaults 镜像里仍有列表条目时，判定文件已被异常清空。
    /// 仅比较列表条目总数（标量开关不参与判断，避免合法的"关开关"误判）。
    /// perAppMargins 的条目计数一并纳入两侧比较。
    func isEmptierThan(userDefaults other: AppTilingSettings) -> Bool {
        let mine = tiledBundleIDs.count + centeredBundleIDs.count + documentChooserBundleIDs.count + perAppMargins.count
        let theirs = other.tiledBundleIDs.count + other.centeredBundleIDs.count + other.documentChooserBundleIDs.count + other.perAppMargins.count
        return mine < theirs
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
        static let edgeMargin = "tiling.edgeMargin"
        static let bundleIDs = "tiling.bundleIDs"
        static let hideSystemApps = "tiling.hideSystemAppsInPicker"
        static let centerEnabled = "centering.enabled"
        static let centeredBundleIDs = "centering.bundleIDs"
        static let documentChooserBundleIDs = "tiling.documentChooserBundleIDs"
        static let perAppMargins = "tiling.perAppMargins"
    }

    private let defaults: UserDefaults
    /// 签名无关的设置文件。默认指向 `~/Library/Application Support/Plumb/settings.json`，
    /// 仅取决于 bundle id 字符串，不依赖签名身份 → OTA 更新后设置不会丢失。
    /// 测试可注入临时路径。
    private let settingsFileURL: URL

    init(defaults: UserDefaults = .standard, settingsFileURL: URL? = nil) {
        self.defaults = defaults
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
        // 1) 优先读文件（签名无关、跨更新稳定）。
        if let fileSettings = readFromFile() {
            // 一致性守卫：文件解码成功，但其列表条目总数严格少于 UserDefaults 镜像时，
            // 视文件为被异常清空（历史上发生过的真实事故：单测/外部工具把空列表写进了真实文件），
            // 改以 UserDefaults 为准并回写修复文件。
            // 判据是「UserDefaults 严格比文件拥有更多列表条目」，因此：
            //   - 正常的双写 save() 不会误触发（save 同步写文件+UserDefaults，两者一致）；
            //   - 用户合法清空列表（save 写入全空）也不会误触发（UserDefaults 镜像同样为空）。
            let udSettings = loadFromUserDefaults()
            if fileSettings.isEmptierThan(userDefaults: udSettings) {
                DiagnosticLog.debug("SettingsStore: load ← FILE lists fewer than UserDefaults → reconciling from UserDefaults \(summary(udSettings))")
                writeToFile(udSettings)
                return udSettings
            }
            DiagnosticLog.debug("SettingsStore: load ← FILE ok \(summary(fileSettings))")
            return fileSettings
        }

        // 2) 文件缺失/损坏 → 读 UserDefaults。
        let userDefaultsSettings = loadFromUserDefaults()
        DiagnosticLog.debug("SettingsStore: load ← UserDefaults (file missing/corrupt) \(summary(userDefaultsSettings))")

        // 3) 一次性迁移：UserDefaults 有非默认数据时，写入文件，之后文件为准。
        //    （UserDefaults 全空 → 返回的就是 .default，不写文件，保持首次启动干净。）
        if userDefaultsSettings != .default {
            DiagnosticLog.debug("SettingsStore: load migrating UserDefaults → file")
            writeToFile(userDefaultsSettings)
        } else {
            DiagnosticLog.debug("SettingsStore: load UserDefaults==.default, no migration")
        }
        return userDefaultsSettings
    }

    /// 设置摘要（用于日志，不含敏感数据，仅计数+开关）。
    func summary(forLog s: AppTilingSettings) -> String {
        "enabled=\(s.isEnabled) centerEnabled=\(s.centerEnabled) margin=\(Int(s.edgeMargin)) tiled=\(s.tiledBundleIDs.count) centered=\(s.centeredBundleIDs.count) chooser=\(s.documentChooserBundleIDs.count) perAppMargins=\(s.perAppMargins.count)"
    }

    private func summary(_ s: AppTilingSettings) -> String {
        summary(forLog: s)
    }

    func save(_ settings: AppTilingSettings) {
        let normalized = settings.normalized()
        DiagnosticLog.debug("SettingsStore: save called \(summary(normalized))")
        // 先写文件（主存储），再写 UserDefaults（镜像，向后兼容）。
        // 任一失败不阻塞另一个：文件写失败仍写 UserDefaults（降级），UserDefaults 写失败不影响文件。
        writeToFile(normalized)
        saveToUserDefaults(normalized)
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

    private func writeToFile(_ settings: AppTilingSettings) {
        let path = settingsFileURL.path
        let data: Data
        do {
            data = try JSONEncoder().encode(settings)
        } catch {
            DiagnosticLog.debug("SettingsStore: writeToFile — JSON encode FAILED: \(error)")
            return
        }
        let dir = settingsFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            DiagnosticLog.debug("SettingsStore: writeToFile — createDirectory FAILED at \(dir.path): \(error)")
            return
        }
        // 原子写：避免写入中途崩溃导致文件损坏。
        do {
            try data.write(to: settingsFileURL, options: [.atomic])
            DiagnosticLog.debug("SettingsStore: writeToFile — wrote \(data.count) bytes to \(path)")
        } catch {
            DiagnosticLog.debug("SettingsStore: writeToFile — data.write FAILED at \(path): \(error)")
        }
    }

    // MARK: - UserDefaults（镜像，向后兼容）

    private func loadFromUserDefaults() -> AppTilingSettings {
        let hasEnabled = defaults.object(forKey: Keys.enabled) != nil
        let hasMargin = defaults.object(forKey: Keys.edgeMargin) != nil
        let hasBundleIDs = defaults.object(forKey: Keys.bundleIDs) != nil
        let hasHideSystemApps = defaults.object(forKey: Keys.hideSystemApps) != nil
        let hasCenterEnabled = defaults.object(forKey: Keys.centerEnabled) != nil
        let hasCenteredBundleIDs = defaults.object(forKey: Keys.centeredBundleIDs) != nil
        let hasDocumentChooserBundleIDs = defaults.object(forKey: Keys.documentChooserBundleIDs) != nil

        if !hasEnabled, !hasMargin, !hasBundleIDs, !hasHideSystemApps,
           !hasCenterEnabled, !hasCenteredBundleIDs, !hasDocumentChooserBundleIDs {
            return .default
        }

        let isEnabled = hasEnabled ? defaults.bool(forKey: Keys.enabled) : AppTilingSettings.default.isEnabled
        let edgeMargin = hasMargin ? defaults.double(forKey: Keys.edgeMargin) : AppTilingSettings.default.edgeMargin
        let bundleIDsArray = defaults.array(forKey: Keys.bundleIDs) as? [String] ?? []
        let hideSystemApps = hasHideSystemApps ? defaults.bool(forKey: Keys.hideSystemApps) : AppTilingSettings.default.hideSystemAppsInPicker
        let centerEnabled = hasCenterEnabled ? defaults.bool(forKey: Keys.centerEnabled) : AppTilingSettings.default.centerEnabled
        let centeredBundleIDsArray = defaults.array(forKey: Keys.centeredBundleIDs) as? [String] ?? []
        // 向后兼容：旧版本无此键时回退到默认预置的 4 个文档类 App。
        let documentChooserBundleIDsArray = hasDocumentChooserBundleIDs
            ? (defaults.array(forKey: Keys.documentChooserBundleIDs) as? [String] ?? [])
            : Array(AppTilingSettings.default.documentChooserBundleIDs)
        // per-app 边距（后增字段）：key 缺失 → 空字典（老版本 settings 全部走默认边距）。
        // UserDefaults 存为 [String: Double]，读出转 CGFloat。
        let perAppMarginsRaw = (defaults.dictionary(forKey: Keys.perAppMargins) as? [String: Double]) ?? [:]
        let perAppMargins = Dictionary(uniqueKeysWithValues: perAppMarginsRaw.map { (k, v) in
            (AppTilingSettings.normalizeBundleID(k), CGFloat(v))
        }.filter { !$0.0.isEmpty })

        return AppTilingSettings(
            isEnabled: isEnabled,
            edgeMargin: edgeMargin,
            tiledBundleIDs: Set(bundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty }),
            hideSystemAppsInPicker: hideSystemApps,
            centerEnabled: centerEnabled,
            centeredBundleIDs: Set(centeredBundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty }),
            documentChooserBundleIDs: Set(documentChooserBundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty }),
            perAppMargins: perAppMargins
        ).normalized()
    }

    private func saveToUserDefaults(_ normalized: AppTilingSettings) {
        defaults.set(normalized.isEnabled, forKey: Keys.enabled)
        defaults.set(Double(normalized.edgeMargin), forKey: Keys.edgeMargin)
        defaults.set(Array(normalized.tiledBundleIDs).sorted(), forKey: Keys.bundleIDs)
        defaults.set(normalized.hideSystemAppsInPicker, forKey: Keys.hideSystemApps)
        defaults.set(normalized.centerEnabled, forKey: Keys.centerEnabled)
        defaults.set(Array(normalized.centeredBundleIDs).sorted(), forKey: Keys.centeredBundleIDs)
        defaults.set(Array(normalized.documentChooserBundleIDs).sorted(), forKey: Keys.documentChooserBundleIDs)
        // per-app 边距镜像双写：CGFloat → Double（UserDefaults 原生支持）。
        let perAppDouble = Dictionary(uniqueKeysWithValues: normalized.perAppMargins.map { ($0.key, Double($0.value)) })
        defaults.set(perAppDouble, forKey: Keys.perAppMargins)
    }
}
