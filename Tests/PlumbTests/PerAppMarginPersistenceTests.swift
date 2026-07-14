import CoreGraphics
import Foundation
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Per-App Tiling Insets 持久化测试
//
// 验证：perAppInsets 双写（文件 + UserDefaults 镜像）往返，以及
// 老版本 settings 无 perAppInsets 键时的向后兼容（回退空字典 → 全部走默认边距）。
// ─────────────────────────────────────────────────────────────────────────────

/// 构造隔离的 store（独立 UserDefaults suite + 临时文件）。
private func makeIsolatedStore() -> (store: AppTilingSettingsStore, defaults: UserDefaults, fileURL: URL, cleanup: () -> Void) {
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    let fileURL = tmpDir.appendingPathComponent("settings.json")
    let store = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    let cleanup: () -> Void = {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }
    return (store, defaults, fileURL, cleanup)
}

@Test
func perAppInsetsRoundTripViaFile() async throws {
    let (store, _, _, cleanup) = makeIsolatedStore()
    defer { cleanup() }

    let input = AppTilingSettings(
        isEnabled: true,
        edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: ["com.a", "com.b"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: [],
        perAppInsets: ["com.a": TileInsets(all: 10), "com.b": TileInsets(all: 30)]
    )

    store.save(input)
    let loaded = store.load()

    // 双写后读回：per-app 间距保留。
    #expect(loaded.perAppInsets == ["com.a": TileInsets(all: 10), "com.b": TileInsets(all: 30)])
    #expect(loaded.effectiveInsets(for: "com.a") == TileInsets(all: 10))
    #expect(loaded.effectiveInsets(for: "com.b") == TileInsets(all: 30))
}

@Test
func perAppInsetsMirroredToUserDefaults() async throws {
    let (store, defaults, _, cleanup) = makeIsolatedStore()
    defer { cleanup() }

    let input = AppTilingSettings(
        isEnabled: true,
        edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: ["com.a"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: [],
        perAppInsets: ["com.a": TileInsets(top: 10, bottom: 20, left: 30, right: 40)]
    )

    store.save(input)

    // UserDefaults 镜像应含 per-app 间距（存为 [String: [String: Double]]）。
    let mirrored = defaults.dictionary(forKey: "tiling.perAppInsets") as? [String: [String: Double]]
    let insets = try #require(mirrored?["com.a"])
    #expect(insets["top"] == 10.0)
    #expect(insets["bottom"] == 20.0)
    #expect(insets["left"] == 30.0)
    #expect(insets["right"] == 40.0)
}

@Test
func explicitEmptyPerAppInsetsSuppressesAndDeletesLegacyMirror() async throws {
    let (store, defaults, fileURL, cleanup) = makeIsolatedStore()
    defer { cleanup() }

    defaults.set(["com.legacy": 28.0], forKey: "tiling.perAppMargins")
    defaults.set(28.0, forKey: "tiling.edgeMargin")

    var settings = AppTilingSettings.default
    settings.perAppInsets = [:]
    store.save(settings)

    #expect(defaults.object(forKey: "tiling.perAppMargins") == nil)
    #expect(defaults.object(forKey: "tiling.edgeMargin") == nil)

    // 模拟权威文件丢失后的 UserDefaults 降级读取。显式空的新键必须胜过任何旧镜像。
    try FileManager.default.removeItem(at: fileURL)
    let freshStore = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    #expect(freshStore.load().perAppInsets.isEmpty)

    // 即使外部旧工具随后又写回 legacy 键，只要新键存在（哪怕为空）也不得迁移旧值。
    defaults.set(["com.legacy": 31.0], forKey: "tiling.perAppMargins")
    let anotherStore = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    #expect(anotherStore.load().perAppInsets.isEmpty)
}

@Test
func explicitEmptyPerAppInsetsInJSONSuppressesLegacyScalarMap() throws {
    let json = """
    {
      "isEnabled": true,
      "edgeInsets": {"top": 16, "bottom": 16, "left": 16, "right": 16},
      "tiledBundleIDs": [],
      "hideSystemAppsInPicker": true,
      "centerEnabled": true,
      "centeredBundleIDs": [],
      "documentChooserBundleIDs": [],
      "perAppInsets": {},
      "perAppMargins": {"com.legacy": 31}
    }
    """

    let decoded = try JSONDecoder().decode(
        AppTilingSettings.self,
        from: try #require(json.data(using: .utf8)))
    #expect(decoded.perAppInsets.isEmpty)
}

@Test
func perAppInsetsBackwardCompatWhenKeyAbsent() async throws {
    // 老版本 settings：UserDefaults 无 tiling.perAppInsets 键，文件也不存在。
    // 读回应回退空 perAppInsets → 全部走默认边距（四向统一）。
    let (store, defaults, _, cleanup) = makeIsolatedStore()
    defer { cleanup() }

    // 仅写老版本的平铺键（无 perAppInsets）。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(16.0, forKey: "tiling.edgeMargin")

    let loaded = store.load()
    #expect(loaded.perAppInsets.isEmpty)
    #expect(loaded.effectiveInsets(for: "com.anything") == TileInsets(all: 16))
}

@Test
func perAppInsetsNormalizedOnSave() async throws {
    // 保存时 key 归一化、value 四向各自钳制，往返后得到规范化的结果。
    let (store, _, _, cleanup) = makeIsolatedStore()
    defer { cleanup() }

    let input = AppTilingSettings(
        isEnabled: true,
        edgeInsets: TileInsets(all: 16),
        tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: [],
        perAppInsets: [
            "  COM.Example.App  ": TileInsets(all: 9999),
            "com.other": TileInsets(top: 40, bottom: 40, left: 40, right: 40)
        ]
    )

    store.save(input)
    let loaded = store.load()

    #expect(loaded.perAppInsets.count == 2)
    #expect(loaded.perAppInsets["com.example.app"] == TileInsets(all: AppTilingSettings.maximumEdgeMargin))
    #expect(loaded.perAppInsets["com.other"] == TileInsets(all: 40))
}

@Test
func perAppInsetsSurviveJsonDecodeWithoutKey() async throws {
    // 模拟老版本写出的 settings.json（不含 perAppInsets 键）：
    // JSONDecoder 必须能解码（回退空字典），而不是抛错。
    // 同时把对应数据写进 UserDefaults（模拟真实双写环境），避免 load() 的一致性守卫
    // 因「文件条目 < UserDefaults 条目」误触发而用 .default 覆盖文件。
    let (store, defaults, fileURL, cleanup) = makeIsolatedStore()
    defer { cleanup() }

    let legacyJSON = """
    {"isEnabled":true,"edgeMargin":20,"tiledBundleIDs":["com.a"],"hideSystemAppsInPicker":true,"centerEnabled":true,"centeredBundleIDs":[],"documentChooserBundleIDs":[]}
    """
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try legacyJSON.data(using: .utf8)!.write(to: fileURL)
    // 与文件保持一致的双写环境（无 perAppInsets 键）。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(20.0, forKey: "tiling.edgeMargin")
    defaults.set(["com.a"], forKey: "tiling.bundleIDs")
    defaults.set(true, forKey: "tiling.hideSystemAppsInPicker")
    defaults.set(true, forKey: "centering.enabled")
    defaults.set([], forKey: "tiling.documentChooserBundleIDs")

    let loaded = store.load()
    #expect(loaded.perAppInsets.isEmpty)
    // 历史标量 edgeMargin=20 → 迁移为全局 edgeInsets 四向 20。
    #expect(loaded.edgeInsets == TileInsets(all: 20))
    #expect(loaded.effectiveInsets(for: "com.a") == TileInsets(all: 20)) // 无 per-app → 全局默认
}
