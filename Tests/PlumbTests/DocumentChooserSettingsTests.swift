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
func documentChooserDefaultsContainPagesNumbersWordExcel() async throws {
    // 默认预置同时覆盖旧 iWork bundle id（com.apple.iwork.pages/numbers）与当前 macOS 实际
    // bundle id（com.apple.Pages/Numbers，归一化后小写），再加 Office（Word/Excel）。
    let defaults = AppTilingSettings.default.documentChooserBundleIDs
    #expect(defaults == [
        "com.apple.iwork.pages",
        "com.apple.iwork.numbers",
        "com.apple.pages",
        "com.apple.numbers",
        "com.microsoft.word",
        "com.microsoft.excel"
    ])
}

@Test
func documentChooserDefaultsMatchCurrentPagesNumbersBundleIDs() async throws {
    // 锁定：当前 macOS 上 Pages/Numbers 实际 bundle id 是 com.apple.Pages / com.apple.Numbers
    //（大小写混合），归一化后命中默认列表 → isDocumentChooserApp 必须为 true。
    let withDefaults = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 16), tiledBundleIDs: [],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: AppTilingSettings.defaultDocumentChooserBundleIDs
    )
    #expect(withDefaults.isDocumentChooserApp(bundleIdentifier: "com.apple.Pages") == true)
    #expect(withDefaults.isDocumentChooserApp(bundleIdentifier: "com.apple.Numbers") == true)
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
        edgeInsets: TileInsets(all: 16),
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
    // 旧版本无 documentChooserBundleIDs 键时应回退到默认预置（6 个 App）。
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
        isEnabled: true, edgeInsets: TileInsets(all: 16), tiledBundleIDs: [],
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
        isEnabled: true, edgeInsets: TileInsets(all: 16), tiledBundleIDs: [],
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
        isEnabled: true, edgeInsets: TileInsets(all: 16),
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
// classifyWindow 三态分类单测（gallery / document / undetermined）。
//
// 背景：文档类 App（Pages/Numbers/Word/Excel）的无 kAXDocument 窗口需三态分类，决定
// 「只居中」还是「平铺」还是「只居中但继续重试」。
//
// 判据是「窗口子树是否含选择器特征 role」+「是否含文档内容 role」。实测签名（2026-06，
// osascript 采 Excel/Word/Pages/Numbers 三态全子树 + 运行时日志）：
//   - Office（Word/Excel）文件列表、iWork（Pages/Numbers）模板画廊：含 AXCollectionList
//   - iWork（Pages/Numbers）文件列表（「打开」面板）：同时含 AXOutline 与 AXBrowser
//   - 真文档窗口（含未保存的「工作簿2/文档1/未命名」）：含 AXLayoutArea/AXTextArea
//   - Office 启动期 0.45s 空壳（运行时日志确证）：什么特征 role 都没有 → undetermined
//
// ⚠️ undetermined 是修复「Excel/Word 文件列表被平铺」的关键：
//   运行时日志确证 Office 在 attach 后 0.45s 首次 handle 时子树还没构建出 AXCollectionList，
//   旧实现把这种空壳当「非选择器」→ 平铺 + processedPIDs.insert 锁死 PID → 即使几秒后子树
//   就绪也永不再评估。改为识别为 .undetermined：只居中、不锁、继续重试直到能明确判定。
// 每个测试对应一个真实采样的窗口，标注其来源。该分类是「文件列表是否被平铺」的关键开关，单独锁定。
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - isChooserRoleSignature（选择器签名子判定，仍保留测试）

@Test
func chooserSignature_officeFileList_isChooser() {
    // Office 文件列表（实测 Excel/Word「打开新的和最近使用的文件」页）含 AXCollectionList → 选择器。
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: true, hasOutline: false, hasBrowser: false) == true)
}

@Test
func chooserSignature_iworkFileList_isChooser() {
    // iWork 文件列表（实测 Pages/Numbers「打开」面板）同时含 AXOutline + AXBrowser → 选择器。
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: false, hasOutline: true, hasBrowser: true) == true)
}

@Test
func chooserSignature_outlineOnly_isNotChooser() {
    // 只有 AXOutline 而无 AXBrowser 不是选择器签名（避免 AXOutline 单独命中误判）。
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: false, hasOutline: true, hasBrowser: false) == false)
}

@Test
func chooserSignature_collectionListDominates() {
    // AXCollectionList 命中即定论（即使另有 Outline/Browser）→ 选择器。
    #expect(WindowEventObserver.isChooserRoleSignature(
        hasCollectionList: true, hasOutline: true, hasBrowser: true) == true)
}

// MARK: - classifyWindow 三态（gallery / document / undetermined）

@Test
func classify_officeFileList_isGallery() {
    // Office 文件列表（实测 Excel/Word）含 AXCollectionList，无文档内容 → .gallery（只居中）。
    #expect(WindowEventObserver.classifyWindow(
        hasCollectionList: true, hasOutline: false, hasBrowser: false,
        hasDocumentContent: false) == .gallery)
}

@Test
func classify_iworkFileList_isGallery() {
    // iWork 文件列表（实测 Pages/Numbers「打开」）含 Outline+Browser → .gallery。
    #expect(WindowEventObserver.classifyWindow(
        hasCollectionList: false, hasOutline: true, hasBrowser: true,
        hasDocumentContent: false) == .gallery)
}

@Test
func classify_iworkTemplateGallery_isGallery() {
    // iWork 模板画廊（实测 Pages/Numbers 模板页）含 CollectionList → .gallery。
    #expect(WindowEventObserver.classifyWindow(
        hasCollectionList: true, hasOutline: false, hasBrowser: false,
        hasDocumentContent: false) == .gallery)
}

@Test
func classify_documentWithContent_isDocument() {
    // 真文档窗口（实测 Excel/Word/Pages/Numbers 文档，含未保存的「工作簿2/文档1/未命名」）
    // 含 AXLayoutArea/AXTextArea 等文档内容 role → .document（应平铺）；AXSplitGroup 不算。
    // 这正是 bbfdd1c 想要「新建未保存文档也平铺」、又不破坏选择器的行为。
    #expect(WindowEventObserver.classifyWindow(
        hasCollectionList: false, hasOutline: false, hasBrowser: false,
        hasDocumentContent: true) == .document)
}

@Test
func classify_officeStartupShell_isUndetermined() {
    // ⭐ 核心修复用例：Office 启动期 0.45s 空壳（运行时日志确证 Excel/Word 文件列表 attach
    // 后首次 handle 时子树未构建出任何特征 role）→ .undetermined（只居中、不锁、继续重试）。
    // 旧实现会把它当 .document → 平铺 + 锁死 PID，这是「文件列表被平铺」的根因。
    #expect(WindowEventObserver.classifyWindow(
        hasCollectionList: false, hasOutline: false, hasBrowser: false,
        hasDocumentContent: false) == .undetermined)
}

@Test
func classify_axFetchFailed_isUndetermined() {
    // AX 取值失败 / 窗口暂无任何特征 role → 同 Office 空壳，保守地视为 .undetermined
    // （只居中、不锁、继续重试），避免拿不到证据就平铺锁死。
    #expect(WindowEventObserver.classifyWindow(
        hasCollectionList: false, hasOutline: false, hasBrowser: false,
        hasDocumentContent: false) == .undetermined)
}

@Test
func classify_gallerySignatureOverridesDocumentContent() {
    // 选择器签名优先于文档内容：即使同时含 CollectionList 和 LayoutArea（理论上选择器
    // 不会有文档内容，但防御性测试），按 .gallery 处理（选择器只居中）。
    #expect(WindowEventObserver.classifyWindow(
        hasCollectionList: true, hasOutline: false, hasBrowser: false,
        hasDocumentContent: true) == .gallery)
}

@Test
func documentClassificationRetry_waitsThenTimesOutWhenSubtreeStaysUndetermined() {
    #expect(WindowEventObserver.documentClassificationRetryDecision(
        for: .undetermined,
        attempt: 1,
        maxAttempts: 6
    ) == .keepWaiting)
    #expect(WindowEventObserver.documentClassificationRetryDecision(
        for: .undetermined,
        attempt: 5,
        maxAttempts: 6
    ) == .keepWaiting)
    #expect(WindowEventObserver.documentClassificationRetryDecision(
        for: .undetermined,
        attempt: 6,
        maxAttempts: 6
    ) == .timedOut)
}

@Test
func documentClassificationRetry_transitionsOnlyAfterPositiveEvidence() {
    #expect(WindowEventObserver.documentClassificationRetryDecision(
        for: .gallery,
        attempt: 1,
        maxAttempts: 6
    ) == .finishGallery)
    #expect(WindowEventObserver.documentClassificationRetryDecision(
        for: .document,
        attempt: 1,
        maxAttempts: 6
    ) == .beginStableGate)
}

@Test
func additionalDocumentAdmissionLetsUndeterminedWindowReachItsClassificationGate() {
    #expect(WindowEventObserver.shouldAdmitAdditionalDocumentWindow(
        hasDocument: false,
        kindWhenUnsaved: .undetermined
    ))
    #expect(WindowEventObserver.shouldAdmitAdditionalDocumentWindow(
        hasDocument: false,
        kindWhenUnsaved: .document
    ))
    #expect(!WindowEventObserver.shouldAdmitAdditionalDocumentWindow(
        hasDocument: false,
        kindWhenUnsaved: .gallery
    ))
    #expect(WindowEventObserver.shouldAdmitAdditionalDocumentWindow(
        hasDocument: true,
        kindWhenUnsaved: .gallery
    ))
}

@Test
func classify_documentContentWithPartialChooser_isDocument() {
    // 只有 AXOutline（无 Browser、无 CollectionList）+ 有文档内容 → 不是选择器签名 → .document。
    // 锁定：Outline 单独出现不构成选择器，文档内容优先。
    #expect(WindowEventObserver.classifyWindow(
        hasCollectionList: false, hasOutline: true, hasBrowser: false,
        hasDocumentContent: true) == .document)
}
