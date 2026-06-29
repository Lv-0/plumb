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
// isChooserRoleSignature 判定单测。
//
// 背景：文档类 App（Pages/Numbers/Word/Excel）有三类「无 kAXDocument」窗口（subrole 均为
// AXStandardWindow）：文件列表、模板选择器、新建未保存文档。仅凭 kAXDocument 无法区分。
// 判据是「窗口子树是否含选择器特有的 AX role 组合」（而非 childCount 阈值——后者只对 Pages
// 实测、对 Excel 失效：Excel 文件列表 childCount=9）。
//
// 实测签名（2026-06，osascript 采 Excel/Word/Pages/Numbers 三态全子树）：
//   - Office（Word/Excel）文件列表、iWork（Pages/Numbers）模板画廊：含 AXCollectionList
//   - iWork（Pages/Numbers）文件列表（「打开」面板）：同时含 AXOutline 与 AXBrowser
//   - 所有文档窗口（含未保存的「未命名/文档1/工作簿2」）：三者皆不含
//
// 该判定同时被 handle() 的 chooser 分支与 handleResize 旁路引用，是「文件列表是否被平铺」的
// 关键开关，故单独锁定以防回归。每个测试对应一个真实采样的窗口，标注其来源。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func chooserSignature_officeFileList_isChooser() {
    // Office 文件列表（实测 Excel/Word「打开新的和最近使用的文件」页）含 AXCollectionList
    // → 是选择器，应只居中、不平铺。
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: true, hasOutline: false, hasBrowser: false) == true)
}

@Test
func chooserSignature_iworkTemplateGallery_isChooser() {
    // iWork 模板选择器画廊（实测 Pages/Numbers 模板页）含 AXCollectionList
    // → 是选择器，应只居中、不平铺。
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: true, hasOutline: false, hasBrowser: false) == true)
}

@Test
func chooserSignature_iworkFileList_isChooser() {
    // iWork 文件列表（实测 Pages/Numbers「打开」面板）同时含 AXOutline + AXBrowser
    // → 是选择器，应只居中、不平铺。
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: false, hasOutline: true, hasBrowser: true) == true)
}

@Test
func chooserSignature_iworkFileList_outlineOnly_isNotChooser() {
    // 只有 AXOutline 而无 AXBrowser 不是 iWork 文件列表签名（避免 AXOutline 单独命中误判）
    // → 不是选择器 → 落入平铺。
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: false, hasOutline: true, hasBrowser: false) == false)
}

@Test
func chooserSignature_document_isNotChooser() {
    // 真实文档窗口（实测 Excel/Word/Pages/Numbers 文档，含未保存的「工作簿2/文档1/未命名」）
    // 三个特征 role 皆不含 → 不是选择器 → 走平铺（这正是 bbfdd1c 想要、且不破坏选择器的行为）。
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: false, hasOutline: false, hasBrowser: false) == false)
}

@Test
func chooserSignature_axFetchFailed_isNotChooser() {
    // AX 取值失败 / 窗口暂无特征 role：保守地视为「不是选择器」→ 落入正常平铺路径。
    // （选择器检测是「正向」匹配：拿不到证据就不拦截平铺，避免误吞真文档窗口。）
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: false, hasOutline: false, hasBrowser: false) == false)
}

@Test
func chooserSignature_collectionListDominates() {
    // AXCollectionList 命中即定论（即使另有 Outline/Browser）→ 是选择器。
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: true, hasOutline: true, hasBrowser: true) == true)
}
