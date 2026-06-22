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

    static let `default` = AppTilingSettings(
        isEnabled: false,
        edgeMargin: defaultEdgeMargin,
        tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: defaultDocumentChooserBundleIDs
    )

    func normalized() -> AppTilingSettings {
        let normalizedTileIDs = Set(tiledBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        let normalizedCenterIDs = Set(centeredBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        let normalizedChooserIDs = Set(documentChooserBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        let normalizedMargin = clamp(edgeMargin, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin)
        return AppTilingSettings(
            isEnabled: isEnabled,
            edgeMargin: normalizedMargin,
            tiledBundleIDs: normalizedTileIDs,
            hideSystemAppsInPicker: hideSystemAppsInPicker,
            centerEnabled: centerEnabled,
            centeredBundleIDs: normalizedCenterIDs,
            documentChooserBundleIDs: normalizedChooserIDs
        )
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
        "enabled=\(s.isEnabled) centerEnabled=\(s.centerEnabled) margin=\(Int(s.edgeMargin)) tiled=\(s.tiledBundleIDs.count) centered=\(s.centeredBundleIDs.count) chooser=\(s.documentChooserBundleIDs.count)"
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

        return AppTilingSettings(
            isEnabled: isEnabled,
            edgeMargin: edgeMargin,
            tiledBundleIDs: Set(bundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty }),
            hideSystemAppsInPicker: hideSystemApps,
            centerEnabled: centerEnabled,
            centeredBundleIDs: Set(centeredBundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty }),
            documentChooserBundleIDs: Set(documentChooserBundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty })
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
    }
}
