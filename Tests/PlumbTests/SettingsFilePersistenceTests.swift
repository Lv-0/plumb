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

    var input = AppTilingSettings(
        isEnabled: true, edgeInsets: TileInsets(all: 24),
        tiledBundleIDs: ["com.microsoft.word", "com.apple.safari"],
        hideSystemAppsInPicker: false,
        centerEnabled: false,
        centeredBundleIDs: ["com.apple.mail"],
        documentChooserBundleIDs: ["com.microsoft.word", "com.microsoft.excel"]
    )
    input.centerOnlyOnAppLaunch = true
    input.tileOnlyOnAppLaunch = true
    store.save(input)

    // 文件应已生成。
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    // 用全新 store（同文件路径）读取——模拟 OTA 后新进程。
    let freshStore = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    let loaded = freshStore.load()

    #expect(loaded == input)
    #expect(loaded.centerOnlyOnAppLaunch)
    #expect(loaded.tileOnlyOnAppLaunch)
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
func filePersistenceCorruptFileFallsBackWithoutReverseMigration() async throws {
    // 仓库契约保留损坏文件时的 UserDefaults 降级恢复，但不得把镜像反向覆盖损坏文件。
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

    let corruptData = try Data(contentsOf: fileURL)
    let loaded = store.load()
    #expect(loaded.isEnabled == true)
    #expect(loaded.tiledBundleIDs == ["com.apple.safari"])
    #expect(try Data(contentsOf: fileURL) == corruptData)
    #expect(defaults.bool(forKey: "tiling.enabled") == true)
    #expect(defaults.array(forKey: "tiling.bundleIDs") as? [String] == ["com.apple.safari"])
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
func filePersistenceDecodableFileWinsOverUserDefaultsWithMoreEntries() async throws {
    // 可解码文件永远是主存储：镜像即使有更多条目，也可能只是上一代的旧值。
    // 条目数不能代替 revision，否则用户合法删除列表项会在下次启动被“复活”。
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // UserDefaults 保留旧数据，列表项比新文件更多。
    defaults.set(true, forKey: "tiling.enabled")
    defaults.set(["com.apple.safari", "com.apple.mail"], forKey: "tiling.bundleIDs")
    defaults.set(["com.apple.mail"], forKey: "centering.bundleIDs")

    // 新文件明确清空列表并关闭居中；这是合法的新一代设置。
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let emptied = AppTilingSettings.default
    try? JSONEncoder().encode(emptied).write(to: fileURL, options: [.atomic])
    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    let loaded = store.load()
    #expect(loaded == emptied)
    // 文件不得被旧镜像回写。
    let reread = try JSONDecoder().decode(AppTilingSettings.self, from: Data(contentsOf: fileURL))
    #expect(reread == emptied)
}

@Test
func filePersistenceValidFileWinsAgainstCompletelyEmptyDefaultsDomain() async throws {
    // 签名身份变化/cfprefsd 域重置时，UserDefaults 可能一个键都没有。
    // loadFromUserDefaults 会将其解释为带 6 个 chooser 的 `.default`；它不得覆盖有效文件。
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    let fileSettings = AppTilingSettings(
        isEnabled: true,
        edgeInsets: TileInsets(top: 11, bottom: 12, left: 13, right: 14),
        tiledBundleIDs: ["com.example.one"],
        hideSystemAppsInPicker: false,
        centerEnabled: false,
        centeredBundleIDs: [],
        documentChooserBundleIDs: [],
        perAppInsets: [:],
        hideStatusBarIcon: true,
        autoCheckUpdates: false
    )
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    try JSONEncoder().encode(fileSettings).write(to: fileURL, options: [.atomic])

    #expect(store.load() == fileSettings)
    #expect(defaults.object(forKey: "tiling.enabled") == nil)
    let reread = try JSONDecoder().decode(AppTilingSettings.self, from: Data(contentsOf: fileURL))
    #expect(reread == fileSettings)
}

@Test
func filePersistenceValidEmptyListsRemainAuthoritativeAgainstDefaultChooserSet() async throws {
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    var fileSettings = AppTilingSettings.default
    fileSettings.documentChooserBundleIDs = []
    fileSettings.centerEnabled = false
    fileSettings.hideStatusBarIcon = true
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    try JSONEncoder().encode(fileSettings).write(to: fileURL, options: [.atomic])

    let loaded = store.load()
    #expect(loaded == fileSettings)
    #expect(loaded.allListsEmpty)
    #expect(loaded.documentChooserBundleIDs.isEmpty)
}

@Test
func filePersistenceLegitimateEmptyListsArePreserved() async throws {
    // 用户合法清空全部列表（经 save 双写）后，权威文件必须原样保留该状态。
    let (defaults, tmpDir, _, store, suiteName) = makeIsolated()
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

@Test
func failedPrimaryWriteDoesNotCacheOrReportUnsavedSettings() throws {
    let (defaults, tmpDir, fileURL, store, suiteName) = makeIsolated()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    var durable = AppTilingSettings.default
    durable.centerEnabled = false
    #expect(store.save(durable))

    let failingStore = AppTilingSettingsStore(
        defaults: defaults,
        settingsFileURL: fileURL,
        fileWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    #expect(failingStore.load() == durable)

    var attempted = durable
    attempted.centerEnabled = true
    attempted.isEnabled = true
    #expect(!failingStore.save(attempted))
    #expect(failingStore.load() == durable)

    // A fresh process still sees the authoritative durable file.
    let restarted = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    #expect(restarted.load() == durable)

    // The failed value must not have entered the mirror either. If the old primary is later
    // lost, fallback recovery must keep the last durable value rather than resurrecting the
    // setting that save() explicitly rejected.
    try FileManager.default.removeItem(at: fileURL)
    let afterPrimaryLoss = AppTilingSettingsStore(defaults: defaults, settingsFileURL: fileURL)
    #expect(afterPrimaryLoss.load() == durable)
    #expect(afterPrimaryLoss.load() != attempted)
}
