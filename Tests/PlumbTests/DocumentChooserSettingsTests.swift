import Foundation
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// 文档选择器感知（documentChooserBundleIDs）相关的设置与判定单测。
//
// 覆盖：
//   - 默认预置含 4 个文档类 App（Pages/Numbers/Word/Excel）。
//   - load/save 往返 + 归一化（大小写/空格）。
//   - 向后兼容：旧版本无此键时回退到默认预置。
//   - isDocumentChooserApp 判定语义（归一化、nil、空集合）。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func documentChooserDefaultsContainFourDocApps() async throws {
    let defaults = AppTilingSettings.default.documentChooserBundleIDs
    #expect(defaults == [
        "com.apple.iwork.pages",
        "com.apple.iwork.numbers",
        "com.microsoft.word",
        "com.microsoft.excel"
    ])
}

@Test
func documentChooserRoundTripAndNormalization() async throws {
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    let fileURL = tmpDir.appendingPathComponent("settings.json")
    let store = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let input = AppTilingSettings(
        isEnabled: true,
        edgeMargin: 16,
        tiledBundleIDs: ["com.apple.iwork.pages", "com.microsoft.word"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: [" COM.MICROSOFT.WORD ", "com.apple.iWork.Pages", "  "]
    )

    store.save(input)
    let loaded = store.load()

    // trim + 小写归一化；空串被过滤。
    #expect(loaded.documentChooserBundleIDs == ["com.microsoft.word", "com.apple.iwork.pages"])
}

@Test
func documentChooserBackwardCompatWhenKeyAbsent() async throws {
    // 旧版本无 documentChooserBundleIDs 键时应回退到默认预置（4 个 App）。
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)

    // 仅写入旧的平铺键（不含 documentChooserBundleIDs）。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(16.0, forKey: "tiling.edgeMargin")
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    let fileURL = tmpDir.appendingPathComponent("settings.json")
    let store = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    let loaded = store.load()
    #expect(loaded.documentChooserBundleIDs == AppTilingSettings.default.documentChooserBundleIDs)
}

@Test
func documentChooserExplicitEmptyPersists() async throws {
    // 用户显式清空列表（全部不启用选择器感知）应被持久化，而非回退到默认。
    let suiteName = "Plumb.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Failed to create isolated UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)

    // 重要：必须注入独立的 settingsFileURL，否则 store 会回退到生产路径
    // ~/Library/Application Support/Plumb/settings.json，并用本测试的空列表覆盖用户真实设置。
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("plumb-tests-\(UUID().uuidString)")
    let fileURL = tmpDir.appendingPathComponent("settings.json")
    let store = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    var settings = AppTilingSettings.default
    settings.documentChooserBundleIDs = []
    store.save(settings)

    let loaded = store.load()
    #expect(loaded.documentChooserBundleIDs.isEmpty)
}

@Test
func isDocumentChooserAppSemantics() async throws {
    // 启用 + 在列表内 => true（大小写/空格归一化）。
    let withDefaults = AppTilingSettings(
        isEnabled: true, edgeMargin: 16, tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: AppTilingSettings.defaultDocumentChooserBundleIDs
    )
    #expect(withDefaults.isDocumentChooserApp(bundleIdentifier: "com.apple.iWork.Pages") == true)
    #expect(withDefaults.isDocumentChooserApp(bundleIdentifier: "  COM.MICROSOFT.WORD  ") == true)
    #expect(withDefaults.isDocumentChooserApp(bundleIdentifier: "com.microsoft.excel") == true)

    // 不在列表内 => false。
    #expect(withDefaults.isDocumentChooserApp(bundleIdentifier: "com.apple.safari") == false)

    // nil => false。
    #expect(withDefaults.isDocumentChooserApp(bundleIdentifier: nil) == false)

    // 空集合 => false（即便 bundleId 非空）。
    let empty = AppTilingSettings(
        isEnabled: true, edgeMargin: 16, tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    #expect(empty.isDocumentChooserApp(bundleIdentifier: "com.microsoft.word") == false)
    #expect(empty.isDocumentChooserApp(bundleIdentifier: nil) == false)
}

@Test
func documentChooserDoesNotAffectShouldTile() async throws {
    // 选择器感知列表与平铺白名单相互独立：isDocumentChooserApp 不改变 shouldTile 语义。
    // 即一个 App 必须同时在 tiledBundleIDs 内才会被平铺。
    let settings = AppTilingSettings(
        isEnabled: true, edgeMargin: 16,
        tiledBundleIDs: [],   // 空白名单 => 无人被平铺
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: AppTilingSettings.defaultDocumentChooserBundleIDs
    )
    // Word 在选择器感知列表内，但不在平铺白名单 => 不应被平铺。
    #expect(settings.isDocumentChooserApp(bundleIdentifier: "com.microsoft.word") == true)
    #expect(settings.shouldTile(bundleIdentifier: "com.microsoft.word") == false)
}

// ─────────────────────────────────────────────────────────────────────────────
// isGalleryChildCount 阈值判定单测。
//
// 背景：文档类 App（Pages/Numbers/Word/Excel）有三类「无 kAXDocument」窗口（subrole 均为
// AXStandardWindow）：文件列表、模板选择器、新建未保存文档。仅凭 kAXDocument 无法区分，
// 用「窗口直接子元素数」区分（基于 Pages 实测：文件列表 kids=1 / 模板选择器 kids=5 / 新文档 kids=6）。
// 该判定同时被 handle() 的 chooser 分支与 handleResize 旁路引用，是「文件列表是否被平铺」的
// 关键开关，故单独锁定以防回归。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func galleryChildCount_fileList_isGallery() {
    // 文件列表（「打开」面板）kids=1 => 非文档窗口，应只居中。
    #expect(WindowEventObserver.isGalleryChildCount(1) == true)
}

@Test
func galleryChildCount_templateGallery_isGallery() {
    // 模板选择器 kids=5 => 非文档窗口，应只居中。
    #expect(WindowEventObserver.isGalleryChildCount(5) == true)
}

@Test
func galleryChildCount_newDocument_isNotGallery() {
    // 新建未保存文档 kids=6 => 是文档窗口，应走平铺。
    #expect(WindowEventObserver.isGalleryChildCount(6) == false)
}

@Test
func galleryChildCount_richDocument_isNotGallery() {
    // 富 UI 新文档（子元素更多）仍应判为文档窗口，走平铺。
    #expect(WindowEventObserver.isGalleryChildCount(10) == false)
    #expect(WindowEventObserver.isGalleryChildCount(100) == false)
}

@Test
func galleryChildCount_axFetchFailed_isGallery() {
    // AX 取值失败/暂无子元素回退到 count=0：保守地视为非文档窗口 → 只居中，
    // 避免对状态未知的窗口强行平铺。
    #expect(WindowEventObserver.isGalleryChildCount(0) == true)
}

@Test
func galleryChildCount_thresholdBoundary() {
    // 边界：threshold-1 => gallery；threshold => 非文档。锁定默认阈值=6 的语义。
    #expect(WindowEventObserver.isGalleryChildCount(6 - 1) == true)
    #expect(WindowEventObserver.isGalleryChildCount(6) == false)
}

@Test
func galleryChildCount_customThreshold() {
    // 自定义阈值（未来若 Numbers/Word/Excel 差异化）应被尊重。
    #expect(WindowEventObserver.isGalleryChildCount(3, threshold: 4) == true)
    #expect(WindowEventObserver.isGalleryChildCount(4, threshold: 4) == false)
}
