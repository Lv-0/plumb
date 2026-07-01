import CoreGraphics
import Foundation
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Per-App Tiling Insets 端到端集成测试
//
// 验证 UI 抽屉交互背后的完整数据链：用户在抽屉设置某 app 四向间距 → store.save() 落盘 →
// 新进程（模拟重启）store.load() 读回 → WindowEventObserver 路径用 effectiveInsets(for:)
// 解析到正确值。"使用默认"（删除 key）→ 回退全局默认（四向统一）。这等价于验证抽屉 UI 的绑定语义：
// 滑块写入 perAppInsets、"使用默认"删除 key、解析走回退。
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
func e2e_setAppInsets_persistsAcrossProcessAndEffectiveAfterRestart() async throws {
    // 模拟用户在抽屉里把 com.slack 设为四向 30px、com.terminal 设为四向 4px。
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
    // 用户拖动抽屉滑块 → UI 通过绑定写入 perAppInsets（等价于 setInsets(value)）。
    settings.perAppInsets["com.slack"] = TileInsets(all: 30)
    settings.perAppInsets["com.tinyspell.terminal"] = TileInsets(all: 4)
    store.save(settings)

    // 模拟重启：新进程、新 UserDefaults、同文件路径读取。
    let freshDefaults = UserDefaults(suiteName: "Plumb.tests.fresh.\(UUID().uuidString)")!
    let freshStore = AppTilingSettingsStore(defaults: freshDefaults, settingsFileURL: fileURL)
    let loaded = freshStore.load()

    // WindowEventObserver 路径：effectiveInsets(for:) 解析——这是实际平铺时用的值。
    #expect(loaded.effectiveInsets(for: "com.slack") == TileInsets(all: 30))               // 自定义
    #expect(loaded.effectiveInsets(for: "com.tinyspell.terminal") == TileInsets(all: 4))   // 自定义
    #expect(loaded.effectiveInsets(for: "com.apple.safari") == TileInsets(all: 16))        // 未设置 → 默认回退
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
    settings.perAppInsets["com.slack"] = TileInsets(all: 30)   // 先设置自定义
    store.save(settings)

    // 用户点"使用默认" → UI 通过绑定删除 key（等价于 setInsets(nil)）。
    var loaded = store.load()
    loaded.perAppInsets.removeValue(forKey: "com.slack")
    store.save(loaded)

    // 重启后验证：com.slack 回退到全局 16（四向统一）。
    // 用同一 store 的文件 + 同一 UserDefaults（save 双写过）模拟真实重启环境，
    // 避免空 UserDefaults 触发 load() 的一致性守卫（真实进程重启时 UserDefaults 不为空）。
    let reloaded = store.load()
    #expect(reloaded.perAppInsets["com.slack"] == nil)
    #expect(reloaded.effectiveInsets(for: "com.slack") == TileInsets(all: 16))
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
    settings.perAppInsets["com.slack"] = TileInsets(all: 30)   // slack 自定义
    store.save(settings)

    // 顶部全局滑块从 16 → 24。
    var loaded = store.load()
    loaded.edgeMargin = 24
    store.save(loaded)

    // 同一 store 重载（save 双写保证文件+UserDefaults 一致，模拟真实重启）。
    let afterGlobal = store.load()

    // slack 保持自定义四向 30；safari（未自定义）跟随新默认 24。
    #expect(afterGlobal.effectiveInsets(for: "com.slack") == TileInsets(all: 30))
    #expect(afterGlobal.effectiveInsets(for: "com.apple.safari") == TileInsets(all: 24))
}

@Test
func e2e_settingsJsonContainsPerAppInsetsKey() async throws {
    // 验证落盘的 JSON 文件确实包含 perAppInsets 字段（不是只在内存）。
    let (_, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    var settings = AppTilingSettings.default
    settings.perAppInsets = ["com.test": TileInsets(top: 10, bottom: 20, left: 30, right: 40)]
    store.save(settings)

    let raw = try Data(contentsOf: fileURL)
    let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    let perApp = try #require(json["perAppInsets"] as? [String: [String: Double]])
    let insets = try #require(perApp["com.test"])
    #expect(insets["top"] == 10.0)
    #expect(insets["bottom"] == 20.0)
    #expect(insets["left"] == 30.0)
    #expect(insets["right"] == 40.0)
}

@Test
func e2e_effectiveInsetsFeedsTiledFrameGeometry() async throws {
    // 验证平铺的实际几何端点：effectiveInsets → WindowGeometry.tiledFrame。
    // 这是 WindowCenteringService 平铺时真正调用的计算。per-app insets 不同 → 平铺目标 frame 不同。
    let visible = CGRect(x: 0, y: 75, width: 1440, height: 800) // 1440x900 主屏扣 Dock+菜单栏

    // app A 自定义边距 40（四向），app B 走默认 16（四向）。
    let settingsA = AppTilingSettings(
        isEnabled: true, edgeMargin: 16,
        tiledBundleIDs: ["com.a", "com.b"],
        hideSystemAppsInPicker: true, centerEnabled: true,
        centeredBundleIDs: [], documentChooserBundleIDs: [],
        perAppInsets: ["com.a": TileInsets(all: 40)]
    )

    let insetsA = settingsA.effectiveInsets(for: "com.a") // 40 四向
    let insetsB = settingsA.effectiveInsets(for: "com.b") // 16 四向（默认回退）

    let frameA = WindowGeometry.tiledFrame(visibleFrame: visible, insets: insetsA)
    let frameB = WindowGeometry.tiledFrame(visibleFrame: visible, insets: insetsB)

    // 自定义大间距 → 平铺目标更小（离边缘更远）。
    #expect(insetsA == TileInsets(all: 40))
    #expect(insetsB == TileInsets(all: 16))
    #expect(frameA.width < frameB.width)
    #expect(frameA.height < frameB.height)
    // 精确几何：A 的左/右内缩各 40。
    #expect(abs(frameA.minX - 40) < 1)
    #expect(abs(frameA.maxX - (1440 - 40)) < 1)
}

@Test
func e2e_asymmetricInsetsProduceAsymmetricFrame() async throws {
    // 验证四向独立：不同方向间距 → 各边内缩不同。
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    let insets = TileInsets(top: 8, bottom: 40, left: 16, right: 24)
    let frame = WindowGeometry.tiledFrame(visibleFrame: visible, insets: insets)

    // 左下原点坐标系：left 加到 minX、bottom 加到 minY。
    #expect(abs(frame.minX - 16) < 1)                    // left
    #expect(abs(frame.minY - 40) < 1)                    // bottom
    #expect(abs(frame.width - (1000 - 16 - 24)) < 1)     // width - left - right
    #expect(abs(frame.height - (800 - 8 - 40)) < 1)      // height - top - bottom
    #expect(abs(frame.maxX - (1000 - 24)) < 1)           // 右边界 = 1000 - right
    #expect(abs(frame.maxY - (800 - 8)) < 1)             // 上边界 = 800 - top
}

// MARK: - 旧格式迁移（perAppMargins 标量 → perAppInsets 四向）

@Test
func e2e_legacyPerAppMarginsJsonMigratedToInsets() async throws {
    // 旧版 settings.json 只含历史标量键 perAppMargins → 解码应迁移为 perAppInsets 四向统一。
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // 构造一份旧格式 JSON：只有 perAppMargins 标量，没有 perAppInsets。
    let legacyJSON = """
    {"isEnabled": true, "edgeMargin": 16, "tiledBundleIDs": ["com.slack"],
     "perAppMargins": {"com.slack": 28}}
    """
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    try legacyJSON.write(to: fileURL, atomically: true, encoding: .utf8)
    _ = defaults  // 仅占位，确保 suite 释放

    let loaded = store.load()
    // 历史标量 28 → 迁移为四向统一 28。
    #expect(loaded.perAppInsets["com.slack"] == TileInsets(all: 28))
    #expect(loaded.effectiveInsets(for: "com.slack") == TileInsets(all: 28))
    // 未设置的 app 仍走全局默认。
    #expect(loaded.effectiveInsets(for: "com.other") == TileInsets(all: 16))
}

@Test
func e2e_legacyPerAppMarginsUserDefaultsMigratedToInsets() async throws {
    // 旧版 UserDefaults 只含历史标量键 tiling.perAppMargins → 读取应迁移为 perAppInsets 四向统一。
    let (defaults, tmpDir, _, store, suiteName) = makeIsolated()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // 直接往 UserDefaults 写旧键（标量字典），不写文件（触发 load 走 UserDefaults 回退）。
    defaults.set(["com.slack": 28.0], forKey: "tiling.perAppMargins")
    defaults.set(true, forKey: "tiling.enabled")

    let loaded = store.load()
    // 历史标量 28 → 迁移为四向统一 28。
    #expect(loaded.perAppInsets["com.slack"] == TileInsets(all: 28))
    #expect(loaded.effectiveInsets(for: "com.slack") == TileInsets(all: 28))
}
