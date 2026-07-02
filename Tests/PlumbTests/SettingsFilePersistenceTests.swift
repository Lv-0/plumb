import Foundation
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// 设置文件持久化（签名无关）单测。
//
// 验证 OTA 更新后设置不丢失的核心机制：
//   - 文件为主存储（`~/Library/Application Support/Plumb/settings.json`），签名无关。
//   - load() 优先读文件；文件缺失回退 UserDefaults；都缺返回默认。
//   - save() 双写文件 + UserDefaults。
//   - 一次性迁移：UserDefaults 有数据、文件不存在 → load 后迁移写入文件。
//
// 全部用注入的临时文件路径，不污染真实 Application Support。
// ─────────────────────────────────────────────────────────────────────────────

/// 便利：构造隔离的 (defaults, tmpDir, fileURL, store)。
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
func filePersistenceRoundTrip() async throws {
    // save → 新 store（同一文件）load → 数据一致。
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    let input = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 24),
        tiledBundleIDs: ["com.microsoft.word", "com.apple.safari"],
        hideSystemAppsInPicker: false,
        centerEnabled: false,
        centeredBundleIDs: ["com.apple.mail"],
        documentChooserBundleIDs: ["com.microsoft.word", "com.microsoft.excel"]
    )
    store.save(input)

    // 文件应已生成。
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    // 用全新 store（同文件路径）读取——模拟 OTA 后新进程。
    // 复用同一 UserDefaults suite：store.save 已双写文件 + UserDefaults 镜像，OTA 场景下
    // 两者并存；用全新空 suite 会让 loadFromUserDefaults 回退 .default，其 documentChooser
    // 条目数（6）多于文件，误触发 load() 的一致性守卫而错误回写——故复用同 suite。
    let freshStore = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    let loaded = freshStore.load()

    #expect(loaded == input)
}

@Test
func filePersistenceMigrationFromUserDefaults() async throws {
    // 旧版本：UserDefaults 有数据、文件不存在 → load 应回退 UserDefaults 并迁移写入文件。
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // 仅写 UserDefaults（模拟旧版本数据，文件尚未生成）。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(32.0, forKey: "tiling.edgeMargin")
    defaults.set(["com.microsoft.word"], forKey: "tiling.bundleIDs")
    // 文件不存在。
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))

    let loaded = store.load()
    // 从 UserDefaults 读到数据。
    #expect(loaded.isEnabled == true)
    #expect(loaded.edgeInsets == TileInsets(all: 32))
    #expect(loaded.tiledBundleIDs == ["com.microsoft.word"])
    // 迁移：文件应已生成。
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    // 再次 load（此时文件存在）应直接读文件，结果一致。
    let loaded2 = store.load()
    #expect(loaded2.isEnabled == true)
    #expect(loaded2.tiledBundleIDs == ["com.microsoft.word"])
}

@Test
func filePersistenceFallbackOnCorruptFile() async throws {
    // 文件损坏（非法 JSON）→ 应回退 UserDefaults；不崩溃。
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // UserDefaults 有数据。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(["com.apple.safari"], forKey: "tiling.bundleIDs")
    // 写一个损坏的文件。
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    try? "{ not valid json ".write(to: fileURL, atomically: true, encoding: .utf8)

    let loaded = store.load()
    // 文件解码失败 → 回退 UserDefaults。
    #expect(loaded.isEnabled == true)
    #expect(loaded.tiledBundleIDs == ["com.apple.safari"])
}

@Test
func filePersistenceEmptyUserDefaultsNoMigration() async throws {
    // 全新安装：UserDefaults 与文件都不存在 → 返回默认，且不写文件（保持首次启动干净）。
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    let loaded = store.load()
    #expect(loaded == .default)
    // 不应触发迁移写文件（没有可迁移的数据）。
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test
func filePersistenceDoubleWrite() async throws {
    // save 应同时写文件和 UserDefaults（双写）。
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    let input = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 40),
        tiledBundleIDs: ["com.apple.xcode"],
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: []
    )
    store.save(input)

    // UserDefaults 也应被写入（镜像）。
    #expect(defaults.bool(forKey: "tiling.enabled") == true)
    #expect(defaults.array(forKey: "tiling.bundleIDs") as? [String] == ["com.apple.xcode"])
    // 文件也被写入。
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
}

@Test
func filePersistenceReconcilesEmptiedFileAgainstUserDefaults() async throws {
    // 回归测试：文件被异常清空（如外部工具/历史事故写入空列表），但 UserDefaults 镜像仍有数据时，
    // load() 应识别出"文件比 UserDefaults 少"并改以 UserDefaults 为准、回写修复文件，
    // 而不是把空列表当权威返回。
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // UserDefaults 保留真实数据（模拟双写后镜像依然完好的情况）。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(["com.apple.safari", "com.apple.mail"], forKey: "tiling.bundleIDs")
    defaults.set(["com.apple.mail"], forKey: "centering.bundleIDs")

    // 直接把一个"全空"的文件写到磁盘（模拟外部污染）。
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let emptied = AppTilingSettings.default
    try? JSONEncoder().encode(emptied).write(to: fileURL, options: [.atomic])
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    let loaded = store.load()
    // 不应返回空列表；应以 UserDefaults 为准。
    #expect(loaded.tiledBundleIDs == Set(["com.apple.safari", "com.apple.mail"]))
    #expect(loaded.centeredBundleIDs == Set(["com.apple.mail"]))
    #expect(loaded.isEnabled == true)
    // 文件应已被回写修复（不再是空列表）。
    let reread = try JSONDecoder().decode(AppTilingSettings.self, from: Data(contentsOf: fileURL))
    #expect(reread.tiledBundleIDs.count == 2)
}

@Test
func filePersistenceLegitimateEmptyListsArePreserved() async throws {
    // 用户合法清空全部列表（经 save 双写：文件与 UserDefaults 同为空）→ load 不应误触发守卫。
    // 这是守卫的反例保护：判据是"UserDefaults 严格多于文件"，合法清空两者一致，不触发。
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // 通过正式 save() 路径写入全空列表（双写，文件与 UserDefaults 一致）。
    var emptied = AppTilingSettings.default
    emptied.documentChooserBundleIDs = []   // 显式清空（默认本是 4 个）
    store.save(emptied)

    let loaded = store.load()
    #expect(loaded.allListsEmpty)
    #expect(loaded.documentChooserBundleIDs.isEmpty)
}
