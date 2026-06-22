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
        edgeMargin: 999,
        tiledBundleIDs: [" COM.Example.App ", "com.example.app", "com.example.other"],
        hideSystemAppsInPicker: false,
        centerEnabled: true,
        centeredBundleIDs: [" COM.Center.App ", "com.center.app"],
        documentChooserBundleIDs: [" COM.Microsoft.Word ", "com.microsoft.excel"]
    )

    store.save(input)
    let loaded = store.load()

    #expect(loaded.isEnabled)
    #expect(loaded.edgeMargin == AppTilingSettings.maximumEdgeMargin)
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

    let input = AppTilingSettings(
        isEnabled: false,
        edgeMargin: AppTilingSettings.defaultEdgeMargin,
        tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: false,
        centeredBundleIDs: ["com.apple.Safari", "  COM.GOOGLE.CHROME  "],
        documentChooserBundleIDs: AppTilingSettings.defaultDocumentChooserBundleIDs
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
}

@Test
func shouldCenterSemantics() async throws {
    // 关闭 => 永不自动居中。
    let disabled = AppTilingSettings(
        isEnabled: true, edgeMargin: 16, tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: false,
        centeredBundleIDs: ["com.apple.safari"],
        documentChooserBundleIDs: []
    )
    #expect(disabled.shouldCenter(bundleIdentifier: "com.apple.safari") == false)
    #expect(disabled.shouldCenter(bundleIdentifier: nil) == false)

    // 开启 + 空列表 => 全部居中（向后兼容）。
    let empty = AppTilingSettings(
        isEnabled: true, edgeMargin: 16, tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    #expect(empty.shouldCenter(bundleIdentifier: "anything.at.all") == true)
    #expect(empty.shouldCenter(bundleIdentifier: nil) == true)

    // 开启 + 非空列表 => 仅列表内（大小写/空格归一化）。
    let allowlist = AppTilingSettings(
        isEnabled: true, edgeMargin: 16, tiledBundleIDs: [],
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
    // 迁移后文件应已生成（含从 UserDefaults 读到的数据）。
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
}
