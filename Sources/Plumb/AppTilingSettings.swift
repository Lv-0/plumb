import CoreGraphics
import Foundation

struct AppTilingSettings: Equatable {
    static let defaultEdgeMargin: CGFloat = 16
    static let minimumEdgeMargin: CGFloat = 0
    static let maximumEdgeMargin: CGFloat = 400

    var isEnabled: Bool
    var edgeMargin: CGFloat
    var tiledBundleIDs: Set<String>
    var hideSystemAppsInPicker: Bool

    /// 居中功能总开关（默认开启，保持既有行为）。
    var centerEnabled: Bool
    /// 仅对列表内 app 自动居中；为空时居中全部 app（向后兼容）。
    var centeredBundleIDs: Set<String>

    static let `default` = AppTilingSettings(
        isEnabled: false,
        edgeMargin: defaultEdgeMargin,
        tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: []
    )

    func normalized() -> AppTilingSettings {
        let normalizedTileIDs = Set(tiledBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        let normalizedCenterIDs = Set(centeredBundleIDs.map(Self.normalizeBundleID).filter { !$0.isEmpty })
        let normalizedMargin = clamp(edgeMargin, min: Self.minimumEdgeMargin, max: Self.maximumEdgeMargin)
        return AppTilingSettings(
            isEnabled: isEnabled,
            edgeMargin: normalizedMargin,
            tiledBundleIDs: normalizedTileIDs,
            hideSystemAppsInPicker: hideSystemAppsInPicker,
            centerEnabled: centerEnabled,
            centeredBundleIDs: normalizedCenterIDs
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
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppTilingSettings {
        let hasEnabled = defaults.object(forKey: Keys.enabled) != nil
        let hasMargin = defaults.object(forKey: Keys.edgeMargin) != nil
        let hasBundleIDs = defaults.object(forKey: Keys.bundleIDs) != nil
        let hasHideSystemApps = defaults.object(forKey: Keys.hideSystemApps) != nil
        let hasCenterEnabled = defaults.object(forKey: Keys.centerEnabled) != nil
        let hasCenteredBundleIDs = defaults.object(forKey: Keys.centeredBundleIDs) != nil

        if !hasEnabled, !hasMargin, !hasBundleIDs, !hasHideSystemApps,
           !hasCenterEnabled, !hasCenteredBundleIDs {
            return .default
        }

        let isEnabled = hasEnabled ? defaults.bool(forKey: Keys.enabled) : AppTilingSettings.default.isEnabled
        let edgeMargin = hasMargin ? defaults.double(forKey: Keys.edgeMargin) : AppTilingSettings.default.edgeMargin
        let bundleIDsArray = defaults.array(forKey: Keys.bundleIDs) as? [String] ?? []
        let hideSystemApps = hasHideSystemApps ? defaults.bool(forKey: Keys.hideSystemApps) : AppTilingSettings.default.hideSystemAppsInPicker
        let centerEnabled = hasCenterEnabled ? defaults.bool(forKey: Keys.centerEnabled) : AppTilingSettings.default.centerEnabled
        let centeredBundleIDsArray = defaults.array(forKey: Keys.centeredBundleIDs) as? [String] ?? []

        return AppTilingSettings(
            isEnabled: isEnabled,
            edgeMargin: edgeMargin,
            tiledBundleIDs: Set(bundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty }),
            hideSystemAppsInPicker: hideSystemApps,
            centerEnabled: centerEnabled,
            centeredBundleIDs: Set(centeredBundleIDsArray.map(AppTilingSettings.normalizeBundleID).filter { !$0.isEmpty })
        ).normalized()
    }

    func save(_ settings: AppTilingSettings) {
        let normalized = settings.normalized()

        defaults.set(normalized.isEnabled, forKey: Keys.enabled)
        defaults.set(Double(normalized.edgeMargin), forKey: Keys.edgeMargin)
        defaults.set(Array(normalized.tiledBundleIDs).sorted(), forKey: Keys.bundleIDs)
        defaults.set(normalized.hideSystemAppsInPicker, forKey: Keys.hideSystemApps)
        defaults.set(normalized.centerEnabled, forKey: Keys.centerEnabled)
        defaults.set(Array(normalized.centeredBundleIDs).sorted(), forKey: Keys.centeredBundleIDs)
    }
}
