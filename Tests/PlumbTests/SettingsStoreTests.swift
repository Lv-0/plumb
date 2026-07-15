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
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    let fileURL = tmpDir.appendingPathComponent("settings.json")
    let store = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    let settings = store.load()

    #expect(settings == .default)
    // 居中默认开启、列表为空（=> 全部居中，向后兼容）。
    #expect(settings.centerEnabled == true)
    #expect(settings.centeredBundleIDs.isEmpty)
    #expect(settings.centerOnlyOnAppLaunch == false)
}

@Test
func settingsStoreRoundTripAndNormalization() async throws {
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    let fileURL = tmpDir.appendingPathComponent("settings.json")
    let store = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    let input = AppTilingSettings(
        isEnabled: true,
        edgeInsets: TileInsets(all: 999),
        tiledBundleIDs: [" COM.Example.App ", "com.example.app", "com.example.other"],
        hideSystemAppsInPicker: false,
        centerEnabled: true,
        centeredBundleIDs: [" COM.Center.App ", "com.center.app"],
        documentChooserBundleIDs: [" COM.Microsoft.Word ", "com.microsoft.excel"]
    )

    store.save(input)
    let loaded = store.load()

    #expect(loaded.isEnabled)
    #expect(loaded.edgeInsets == TileInsets(all: AppTilingSettings.maximumEdgeMargin))
    #expect(loaded.tiledBundleIDs == ["com.example.app", "com.example.other"])
    #expect(loaded.hideSystemAppsInPicker == false)
    #expect(loaded.centerEnabled == true)
    #expect(loaded.centeredBundleIDs == ["com.center.app"])
    #expect(loaded.documentChooserBundleIDs == ["com.microsoft.word", "com.microsoft.excel"])
}

@Test
func settingsStoreCenteringRoundTrip() async throws {
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    let fileURL = tmpDir.appendingPathComponent("settings.json")
    let store = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    var input = AppTilingSettings(
        isEnabled: false,
        edgeInsets: TileInsets(all: AppTilingSettings.defaultEdgeMargin),
        tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: false,
        centeredBundleIDs: ["com.apple.Safari", "  COM.GOOGLE.CHROME  "],
        documentChooserBundleIDs: AppTilingSettings.defaultDocumentChooserBundleIDs
    )
    input.centerOnlyOnAppLaunch = true

    store.save(input)
    let loaded = store.load()

    #expect(loaded.centerEnabled == false)
    #expect(loaded.centeredBundleIDs == ["com.apple.safari", "com.google.chrome"])
    #expect(loaded.centerOnlyOnAppLaunch == true)
    #expect(defaults.bool(forKey: "centering.onlyOnAppLaunch") == true)

    // 切换为开启并清空列表。
    var enabled = loaded
    enabled.centerEnabled = true
    enabled.centeredBundleIDs = []
    store.save(enabled)
    let loaded2 = store.load()
    #expect(loaded2.centerEnabled == true)
    #expect(loaded2.centeredBundleIDs.isEmpty)
    #expect(loaded2.centerOnlyOnAppLaunch == true)
}

@Test
func shouldCenterSemantics() async throws {
    // 关闭 => 永不自动居中。
    let disabled = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16), tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: false,
        centeredBundleIDs: ["com.apple.safari"],
        documentChooserBundleIDs: []
    )
    #expect(disabled.shouldCenter(bundleIdentifier: "com.apple.safari") == false)
    #expect(disabled.shouldCenter(bundleIdentifier: nil) == false)

    // 开启 + 空列表 => 全部居中（向后兼容）。
    let empty = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16), tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    #expect(empty.shouldCenter(bundleIdentifier: "anything.at.all") == true)
    #expect(empty.shouldCenter(bundleIdentifier: nil) == true)

    // 开启 + 非空列表 => 仅列表内（大小写/空格归一化）。
    let allowlist = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16), tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: ["com.apple.safari", "com.google.chrome"],
        documentChooserBundleIDs: []
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
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    let fileURL = tmpDir.appendingPathComponent("settings.json")
    let store = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // 仅写入旧的平铺键（UserDefaults）。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(16.0, forKey: "tiling.edgeMargin")

    // 文件不存在 → 应回退 UserDefaults 并迁移。
    let loaded = store.load()
    #expect(loaded.centerEnabled == AppTilingSettings.default.centerEnabled)
    #expect(loaded.centeredBundleIDs == AppTilingSettings.default.centeredBundleIDs)
    #expect(loaded.centerOnlyOnAppLaunch == false)
    // 迁移后文件应已生成（含从 UserDefaults 读到的数据）。
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
}

@Test
func settingsStoreRecognizesLaunchOnlyKeyAsNonEmptyDomain() async throws {
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    let fileURL = tmpDir.appendingPathComponent("settings.json")
    let store = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    defaults.set(true, forKey: "centering.onlyOnAppLaunch")
    let loaded = store.load()

    #expect(loaded.centerOnlyOnAppLaunch)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
}

@Test
func settingsJSONWithoutLaunchOnlyKeyKeepsHistoricalBehavior() throws {
    let legacyJSON = Data(#"{"centerEnabled":true,"centeredBundleIDs":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(AppTilingSettings.self, from: legacyJSON)

    #expect(decoded.centerEnabled)
    #expect(decoded.centerOnlyOnAppLaunch == false)
}

// MARK: - resolvedAutomaticLayout (tile/center 互斥、平铺优先)

@Test
func resolvedLayoutTileWinsWhenAppInBothAllowlists() async throws {
    // 一个 bundle id 合法地同时出现在 tiledBundleIDs 与 centeredBundleIDs（历史/用户选择）。
    // 运行时必须确定性地解析为 .tile——平铺优先，不修改用户的设置。
    let settings = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: ["com.netease.163music"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: ["com.netease.163music"],
        documentChooserBundleIDs: []
    )
    #expect(settings.resolvedAutomaticLayout(for: "com.netease.163music") == .tile)
    // 归一化（大小写/空格）后仍命中。
    #expect(settings.resolvedAutomaticLayout(for: "  COM.NETEASE.163MUSIC  ") == .tile)
}

@Test
func resolvedLayoutTileOnly() async throws {
    let settings = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: ["com.apple.finder"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    #expect(settings.resolvedAutomaticLayout(for: "com.apple.finder") == .tile)
}

@Test
func resolvedLayoutCenterOnly() async throws {
    let settings = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: ["com.apple.safari"],
        documentChooserBundleIDs: []
    )
    #expect(settings.resolvedAutomaticLayout(for: "com.apple.safari") == .center)
}

@Test
func resolvedLayoutNoneWhenAppInNeitherAndAllowlistsNonEmpty() async throws {
    // 列表非空 → 仅列表内；不在任何列表 → .none。
    let settings = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: ["com.apple.finder"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: ["com.apple.safari"],
        documentChooserBundleIDs: []
    )
    #expect(settings.resolvedAutomaticLayout(for: "com.other.app") == .none)
    #expect(settings.resolvedAutomaticLayout(for: nil) == .none)
}

@Test
func resolvedLayoutCenterWhenTilingDisabledButCenteringEnabled() async throws {
    // 平铺总开关关闭 → shouldTile 恒 false；居中开启 + 空列表 → 全部居中。
    let settings = AppTilingSettings(
        isEnabled: false, edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: ["com.apple.finder"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    #expect(settings.resolvedAutomaticLayout(for: "com.apple.finder") == .center)
    #expect(settings.resolvedAutomaticLayout(for: "anything") == .center)
}

@Test
func resolvedLayoutTileWhenCenteringDisabledButTilingEnabled() async throws {
    // 居中关闭、平铺开启且在平铺白名单 → .tile（平铺不依赖居中开关）。
    let settings = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: ["com.apple.finder"],
        hideSystemAppsInPicker: true,
        centerEnabled: false,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    #expect(settings.resolvedAutomaticLayout(for: "com.apple.finder") == .tile)
    // 不在平铺白名单 → .none（居中已关闭）。
    #expect(settings.resolvedAutomaticLayout(for: "com.other.app") == .none)
}

@Test
func resolvedLayoutPreservesBundleIDNormalization() async throws {
    let settings = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: ["com.apple.pages"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: ["com.apple.PAGES"],   // 归一化后与平铺白名单同一 key
        documentChooserBundleIDs: []
    )
    // 大小写/空格差异不影响：归一化后命中 → 平铺优先。
    #expect(settings.resolvedAutomaticLayout(for: "Com.Apple.Pages") == .tile)
    #expect(settings.resolvedAutomaticLayout(for: " com.apple.pages ") == .tile)
}

@Test
func resolvedLayoutPreservesEmptyCenteredBundleIDsSemantics() async throws {
    // 空 centeredBundleIDs => 居中全部；但平铺优先，故平铺白名单内 app 仍为 .tile，
    // 不在平铺白名单的任意 app 为 .center（空列表=全部居中的既有语义）。
    let settings = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: ["com.apple.finder"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    #expect(settings.resolvedAutomaticLayout(for: "com.apple.finder") == .tile)
    #expect(settings.resolvedAutomaticLayout(for: "com.other.app") == .center)
    #expect(settings.resolvedAutomaticLayout(for: nil) == .center)
}
