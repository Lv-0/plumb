import CoreGraphics
import Foundation
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Per-App Tiling Margin 持久化测试
//
// 验证：perAppMargins 双写（文件 + UserDefaults 镜像）往返，以及
// 老版本 settings 无 perAppMargins 键时的向后兼容（回退空字典 → 全部走默认边距）。
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
func perAppMarginsRoundTripViaFile() async throws {
    let (store, _, _, cleanup) = makeIsolatedStore()
    defer { cleanup() }

    let input = AppTilingSettings(
        isEnabled: true,
        edgeMargin: 16,
        tiledBundleIDs: ["com.a", "com.b"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: [],
        perAppMargins: ["com.a": 10, "com.b": 30]
    )

    store.save(input)
    let loaded = store.load()

    // 双写后读回：per-app 边距保留。
    #expect(loaded.perAppMargins == ["com.a": 10, "com.b": 30])
    #expect(loaded.effectiveMargin(for: "com.a") == 10)
    #expect(loaded.effectiveMargin(for: "com.b") == 30)
}

@Test
func perAppMarginsMirroredToUserDefaults() async throws {
    let (store, defaults, _, cleanup) = makeIsolatedStore()
    defer { cleanup() }

    let input = AppTilingSettings(
        isEnabled: true,
        edgeMargin: 16,
        tiledBundleIDs: ["com.a"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: [],
        perAppMargins: ["com.a": 24]
    )

    store.save(input)

    // UserDefaults 镜像应含 per-app 边距（存为 [String: Double]）。
    let mirrored = defaults.dictionary(forKey: "tiling.perAppMargins") as? [String: Double]
    #expect(mirrored?["com.a"] == 24.0)
}

@Test
func perAppMarginsBackwardCompatWhenKeyAbsent() async throws {
    // 老版本 settings：UserDefaults 无 tiling.perAppMargins 键，文件也不存在。
    // 读回应回退空 perAppMargins → 全部走默认边距。
    let (store, defaults, _, cleanup) = makeIsolatedStore()
    defer { cleanup() }

    // 仅写老版本的平铺键（无 perAppMargins）。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(16.0, forKey: "tiling.edgeMargin")

    let loaded = store.load()
    #expect(loaded.perAppMargins.isEmpty)
    #expect(loaded.effectiveMargin(for: "com.anything") == 16)
}

@Test
func perAppMarginsNormalizedOnSave() async throws {
    // 保存时 key 归一化、value 钳制，往返后得到规范化的结果。
    let (store, _, _, cleanup) = makeIsolatedStore()
    defer { cleanup() }

    let input = AppTilingSettings(
        isEnabled: true,
        edgeMargin: 16,
        tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: [],
        perAppMargins: ["  COM.Example.App  ": 9999, "com.other": 40]
    )

    store.save(input)
    let loaded = store.load()

    #expect(loaded.perAppMargins.count == 2)
    #expect(loaded.perAppMargins["com.example.app"] == AppTilingSettings.maximumEdgeMargin)
    #expect(loaded.perAppMargins["com.other"] == 40)
}

@Test
func perAppMarginsSurviveJsonDecodeWithoutKey() async throws {
    // 模拟老版本写出的 settings.json（不含 perAppMargins 键）：
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
    // 与文件保持一致的双写环境（无 perAppMargins 键）。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(20.0, forKey: "tiling.edgeMargin")
    defaults.set(["com.a"], forKey: "tiling.bundleIDs")
    defaults.set(true, forKey: "tiling.hideSystemAppsInPicker")
    defaults.set(true, forKey: "centering.enabled")
    defaults.set([], forKey: "tiling.documentChooserBundleIDs")

    let loaded = store.load()
    #expect(loaded.perAppMargins.isEmpty)
    #expect(loaded.edgeMargin == 20)
    #expect(loaded.effectiveMargin(for: "com.a") == 20) // 无 per-app → 全局默认
}
