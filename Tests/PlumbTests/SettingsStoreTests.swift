import Foundation
import Testing
@testable import Plumb

@Test
func settingsStoreDefaultValues() async throws {
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)

    let store = AppTilingSettingsStore(defaults: defaults)
    let settings = store.load()

    #expect(settings == .default)
    // 居中默认开启、列表为空（=> 全部居中，向后兼容）。
    #expect(settings.centerEnabled == true)
    #expect(settings.centeredBundleIDs.isEmpty)

    defaults.removePersistentDomain(forName: suiteName)
}

@Test
func settingsStoreRoundTripAndNormalization() async throws {
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)

    let store = AppTilingSettingsStore(defaults: defaults)

    let input = AppTilingSettings(
        isEnabled: true,
        edgeMargin: 999,
        tiledBundleIDs: [" COM.Example.App ", "com.example.app", "com.example.other"],
        hideSystemAppsInPicker: false,
        centerEnabled: true,
        centeredBundleIDs: [" COM.Center.App ", "com.center.app"]
    )

    store.save(input)
    let loaded = store.load()

    #expect(loaded.isEnabled)
    #expect(loaded.edgeMargin == AppTilingSettings.maximumEdgeMargin)
    #expect(loaded.tiledBundleIDs == ["com.example.app", "com.example.other"])
    #expect(loaded.hideSystemAppsInPicker == false)
    #expect(loaded.centerEnabled == true)
    #expect(loaded.centeredBundleIDs == ["com.center.app"])

    defaults.removePersistentDomain(forName: suiteName)
}

@Test
func settingsStoreCenteringRoundTrip() async throws {
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)

    let store = AppTilingSettingsStore(defaults: defaults)

    let input = AppTilingSettings(
        isEnabled: false,
        edgeMargin: AppTilingSettings.defaultEdgeMargin,
        tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: false,
        centeredBundleIDs: ["com.apple.Safari", "  COM.GOOGLE.CHROME  "]
    )

    store.save(input)
    let loaded = store.load()

    #expect(loaded.centerEnabled == false)
    #expect(loaded.centeredBundleIDs == ["com.apple.safari", "com.google.chrome"])

    // 切换为开启并清空列表。
    var enabled = loaded
    enabled.centerEnabled = true
    enabled.centeredBundleIDs = []
    store.save(enabled)
    let loaded2 = store.load()
    #expect(loaded2.centerEnabled == true)
    #expect(loaded2.centeredBundleIDs.isEmpty)

    defaults.removePersistentDomain(forName: suiteName)
}

@Test
func shouldCenterSemantics() async throws {
    // 关闭 => 永不自动居中。
    let disabled = AppTilingSettings(
        isEnabled: true, edgeMargin: 16, tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: false,
        centeredBundleIDs: ["com.apple.safari"]
    )
    #expect(disabled.shouldCenter(bundleIdentifier: "com.apple.safari") == false)
    #expect(disabled.shouldCenter(bundleIdentifier: nil) == false)

    // 开启 + 空列表 => 全部居中（向后兼容）。
    let empty = AppTilingSettings(
        isEnabled: true, edgeMargin: 16, tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: []
    )
    #expect(empty.shouldCenter(bundleIdentifier: "anything.at.all") == true)
    #expect(empty.shouldCenter(bundleIdentifier: nil) == true)

    // 开启 + 非空列表 => 仅列表内（大小写/空格归一化）。
    let allowlist = AppTilingSettings(
        isEnabled: true, edgeMargin: 16, tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: ["com.apple.safari", "com.google.chrome"]
    )
    #expect(allowlist.shouldCenter(bundleIdentifier: "com.apple.Safari") == true)
    #expect(allowlist.shouldCenter(bundleIdentifier: "  COM.GOOGLE.CHROME  ") == true)
    #expect(allowlist.shouldCenter(bundleIdentifier: "com.other.app") == false)
    #expect(allowlist.shouldCenter(bundleIdentifier: nil) == false)
}

@Test
func settingsStoreBackwardCompatWhenCenterKeysAbsent() async throws {
    // 当仅存在旧的平铺相关键、缺少居中相关键时，居中字段应回退到默认值（开启、空列表）。
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)

    // 仅写入旧的平铺键。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(16.0, forKey: "tiling.edgeMargin")

    let store = AppTilingSettingsStore(defaults: defaults)
    let loaded = store.load()
    #expect(loaded.centerEnabled == AppTilingSettings.default.centerEnabled)
    #expect(loaded.centeredBundleIDs == AppTilingSettings.default.centeredBundleIDs)

    defaults.removePersistentDomain(forName: suiteName)
}
