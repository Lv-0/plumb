import Foundation
import Testing
@testable import Plumb

// 「隐藏菜单栏图标」功能的持久化/默认值/向后兼容测试。
// 该字段为后增字段：旧 settings.json 不含此键时应回退到 false（默认显示图标）。
// 覆盖：默认值、UserDefaults 镜像 round-trip、缺失键向后兼容。

@Test
func hideStatusBarIconDefaultsToFalse() async throws {
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

    // 无任何设置时，应等于 .default（其 hideStatusBarIcon == false）。
    let settings = store.load()
    #expect(settings.hideStatusBarIcon == false)
    #expect(settings.hideStatusBarIcon == AppTilingSettings.default.hideStatusBarIcon)
}

@Test
func hideStatusBarIconRoundTrip() async throws {
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

    // 写入 hideStatusBarIcon = true，保存后用新 store 读取，应保持 true。
    var input = AppTilingSettings.default
    input.hideStatusBarIcon = true
    store.save(input)

    // 新 store（清空内存状态，强制从文件/UserDefaults 重读）。
    let store2 = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    let loaded = store2.load()
    #expect(loaded.hideStatusBarIcon == true)

    // 切回 false 应同样持久化。
    var back = loaded
    back.hideStatusBarIcon = false
    store.save(back)
    let loaded2 = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL).load()
    #expect(loaded2.hideStatusBarIcon == false)
}

@Test
func hideStatusBarIconBackwardCompatWhenKeyAbsent() async throws {
    // 模拟旧版本：仅写入平铺/居中等既有键，不含 appearance.hideStatusBarIcon。
    // 加载时应回退到默认值 false，而非崩溃或读出 true。
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

    // 仅写入旧键，刻意不写 appearance.hideStatusBarIcon。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(16.0, forKey: "tiling.edgeMargin")
    #expect(defaults.object(forKey: "appearance.hideStatusBarIcon") == nil)

    let loaded = store.load()
    #expect(loaded.hideStatusBarIcon == false)
    #expect(loaded.isEnabled == true)
}

@Test
func hideStatusBarIconDecodedFromJSONWithoutKeyFallsBack() async throws {
    // 模拟旧版本写出的 settings.json（不含 hideStatusBarIcon 键）。
    // 直接走 Codable 解码路径，确认 decodeIfPresent 回退逻辑生效。
    let json = """
    {
      "isEnabled": true,
      "edgeMargin": 16,
      "tiledBundleIDs": [],
      "hideSystemAppsInPicker": true,
      "centerEnabled": true,
      "centeredBundleIDs": [],
      "documentChooserBundleIDs": [],
      "perAppMargins": {}
    }
    """
    let data = try #require(json.data(using: .utf8))
    let decoded = try JSONDecoder().decode(AppTilingSettings.self, from: data)
    #expect(decoded.hideStatusBarIcon == false)

    // 含该键时正确读出。
    let jsonWithKey = """
    {
      "isEnabled": false,
      "edgeMargin": 12,
      "tiledBundleIDs": [],
      "hideSystemAppsInPicker": true,
      "centerEnabled": true,
      "centeredBundleIDs": [],
      "documentChooserBundleIDs": [],
      "perAppMargins": {},
      "hideStatusBarIcon": true
    }
    """
    let data2 = try #require(jsonWithKey.data(using: .utf8))
    let decoded2 = try JSONDecoder().decode(AppTilingSettings.self, from: data2)
    #expect(decoded2.hideStatusBarIcon == true)
}
