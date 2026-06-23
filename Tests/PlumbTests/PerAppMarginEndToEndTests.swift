import CoreGraphics
import Foundation
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Per-App Tiling Margin 端到端集成测试
//
// 验证 UI 抽屉交互背后的完整数据链：用户在抽屉设置某 app 边距 → store.save() 落盘 →
// 新进程（模拟重启）store.load() 读回 → WindowEventObserver 路径用 effectiveMargin(for:)
// 解析到正确值。"使用默认"（删除 key）→ 回退全局默认。这等价于验证抽屉 UI 的绑定语义：
// 滑块写入 perAppMargins、"使用默认"删除 key、解析走回退。
// ─────────────────────────────────────────────────────────────────────────────

private func makeIsolated() -> (defaults: UserDefaults, tmpDir: URL, fileURL: URL, store: AppTilingSettingsStore, suiteName: String) {
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    let fileURL = tmpDir.appendingPathComponent("settings.json")
    let store = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    return (defaults, tmpDir, fileURL, store, suiteName)
}

@Test
func e2e_setAppMargin_persistsAcrossProcessAndEffectiveAfterRestart() async throws {
    // 模拟用户在抽屉里把 com.slack 设为 30px、com.terminal 设为 4px。
    let (_, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    var settings = AppTilingSettings(
        isEnabled: true, edgeMargin: 16,
        tiledBundleIDs: ["com.slack", "com.tinyspell.terminal", "com.apple.safari"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    // 用户拖动抽屉滑块 → UI 通过绑定写入 perAppMargins（等价于 setMargin(value)）。
    settings.perAppMargins["com.slack"] = 30
    settings.perAppMargins["com.tinyspell.terminal"] = 4
    store.save(settings)

    // 模拟重启：新进程、新 UserDefaults、同文件路径读取。
    let freshDefaults = UserDefaults(suiteName: "Plumb.tests.fresh.\(UUID().uuidString)")!
    let freshStore = AppTilingSettingsStore(defaults: freshDefaults, settingsFileURL: fileURL)
    let loaded = freshStore.load()

    // WindowEventObserver 路径：effectiveMargin(for:) 解析——这是实际平铺时用的值。
    #expect(loaded.effectiveMargin(for: "com.slack") == 30)               // 自定义
    #expect(loaded.effectiveMargin(for: "com.tinyspell.terminal") == 4)   // 自定义
    #expect(loaded.effectiveMargin(for: "com.apple.safari") == 16)        // 未设置 → 默认回退
}

@Test
func e2e_useDefault_resetsToGlobalAndPersists() async throws {
    // 模拟用户点"使用默认"：删除该 app 的 key → 回退全局默认，且跨重启生效。
    let (_, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    var settings = AppTilingSettings(
        isEnabled: true, edgeMargin: 16,
        tiledBundleIDs: ["com.slack"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    settings.perAppMargins["com.slack"] = 30   // 先设置自定义
    store.save(settings)

    // 用户点"使用默认" → UI 通过绑定删除 key（等价于 setMargin(nil)）。
    var loaded = store.load()
    loaded.perAppMargins.removeValue(forKey: "com.slack")
    store.save(loaded)

    // 重启后验证：com.slack 回退到全局 16。
    // 用同一 store 的文件 + 同一 UserDefaults（save 双写过）模拟真实重启环境，
    // 避免空 UserDefaults 触发 load() 的一致性守卫（真实进程重启时 UserDefaults 不为空）。
    let reloaded = store.load()
    #expect(reloaded.perAppMargins["com.slack"] == nil)
    #expect(reloaded.effectiveMargin(for: "com.slack") == 16)
}

@Test
func e2e_defaultMarginChangePropagatesToAllDefaultApps() async throws {
    // 用户拖动顶部全局滑块改变默认边距 → 所有"未自定义"的 app 跟随，自定义的不变。
    let (_, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    var settings = AppTilingSettings(
        isEnabled: true, edgeMargin: 16,
        tiledBundleIDs: ["com.slack", "com.apple.safari"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    settings.perAppMargins["com.slack"] = 30   // slack 自定义
    store.save(settings)

    // 顶部全局滑块从 16 → 24。
    var loaded = store.load()
    loaded.edgeMargin = 24
    store.save(loaded)

    // 同一 store 重载（save 双写保证文件+UserDefaults 一致，模拟真实重启）。
    let afterGlobal = store.load()

    // slack 保持自定义 30；safari（未自定义）跟随新默认 24。
    #expect(afterGlobal.effectiveMargin(for: "com.slack") == 30)
    #expect(afterGlobal.effectiveMargin(for: "com.apple.safari") == 24)
}

@Test
func e2e_settingsJsonContainsPerAppMarginsKey() async throws {
    // 验证落盘的 JSON 文件确实包含 perAppMargins 字段（不是只在内存）。
    let (_, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    var settings = AppTilingSettings.default
    settings.perAppMargins = ["com.test": 42]
    store.save(settings)

    let raw = try Data(contentsOf: fileURL)
    let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    let perApp = try #require(json["perAppMargins"] as? [String: Double])
    #expect(perApp["com.test"] == 42.0)
}

@Test
func e2e_effectiveMarginFeedsTiledFrameGeometry() async throws {
    // 验证平铺的实际几何端点：effectiveMargin → WindowGeometry.tiledFrame。
    // 这是 WindowCenteringService 平铺时真正调用的计算。per-app margin 不同 → 平铺目标 frame 不同。
    let visible = CGRect(x: 0, y: 75, width: 1440, height: 800) // 1440x900 主屏扣 Dock+菜单栏

    // app A 自定义边距 40，app B 走默认 16。
    let settingsA = AppTilingSettings(
        isEnabled: true, edgeMargin: 16,
        tiledBundleIDs: ["com.a", "com.b"],
        hideSystemAppsInPicker: true, centerEnabled: true,
        centeredBundleIDs: [], documentChooserBundleIDs: [],
        perAppMargins: ["com.a": 40]
    )

    let marginA = settingsA.effectiveMargin(for: "com.a") // 40
    let marginB = settingsA.effectiveMargin(for: "com.b") // 16（默认回退）

    let frameA = WindowGeometry.tiledFrame(visibleFrame: visible, edgeMargin: marginA)
    let frameB = WindowGeometry.tiledFrame(visibleFrame: visible, edgeMargin: marginB)

    // 自定义大边距 → 平铺目标更小（离边缘更远）。
    #expect(marginA == 40)
    #expect(marginB == 16)
    #expect(frameA.width < frameB.width)
    #expect(frameA.height < frameB.height)
    // 精确几何：A 的左/右内缩各 40。
    #expect(abs(frameA.minX - 40) < 1)
    #expect(abs(frameA.maxX - (1440 - 40)) < 1)
}
