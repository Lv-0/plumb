# In-App OTA Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add self-built in-app auto-update (OTA) to Plumb so users can upgrade with one click instead of manually downloading a DMG, while preserving TCC permissions across updates.

**Architecture:** A single SwiftPM target with two entry modes — normal (`AppDelegate`) and installer (`installerMode` UserDefaults flag), mirroring the existing self-test harness convention. On detecting a newer version (semver compare against a repo-hosted `appcast.json`), the app downloads a sha256-verified zip, then relaunches itself into installer mode, where a privileged helper atomically replaces `/Applications/Plumb.app` and relaunches it. No third-party dependencies; CryptoKit for sha256.

**Tech Stack:** Swift 6.2 (macOS 26), swift-testing, AppKit, CryptoKit (SHA256), Security framework (AuthorizationCopyRights).

**Spec:** `docs/superpowers/specs/2026-06-20-ota-update-design.md`

---

## File Structure

| File | Responsibility | Status |
|------|----------------|--------|
| `Sources/Plumb/AppVersion.swift` | Pure semver parse + compare; read current version from bundle. | **Create** |
| `Sources/Plumb/UpdateManifest.swift` | `Codable` model for appcast.json + localized notes lookup. | **Create** |
| `Sources/Plumb/UpdateChecker.swift` | Fetch appcast, compare versions, minOS gate; `ManifestFetcher` protocol for testability. | **Create** |
| `Sources/Plumb/UpdateDownloader.swift` | Download zip, sha256 verify, unzip to temp app. | **Create** |
| `Sources/Plumb/UpdateCoordinator.swift` | Orchestrates check → prompt → download → relaunch into installer. Main app's single entry point. | **Create** |
| `Sources/Plumb/UpdateInstaller.swift` | Installer-mode UI + privileged atomic replace + relaunch. | **Create** |
| `Sources/Plumb/Localization.swift` | Add OTA keys to `Key` enum + all 5 language tables + accessors. | **Modify** |
| `Sources/Plumb/AppDelegate.swift` | Add "Check for Updates…" menu item + background check on launch. | **Modify** |
| `Sources/Plumb/main.swift` | Add `installerMode` branch (after self-test branches, before normal `AppDelegate`). | **Modify** |
| `Tests/PlumbTests/AppVersionTests.swift` | semver comparison unit tests. | **Create** |
| `Tests/PlumbTests/UpdateManifestTests.swift` | JSON decoding + localized notes fallback tests. | **Create** |
| `Tests/PlumbTests/UpdateCheckerTests.swift` | Version compare + minOS gate via MockManifestFetcher (no network). | **Create** |
| `Tests/PlumbTests/UpdateDownloaderTests.swift` | sha256 verify against fixed temp file (no network). | **Create** |
| `scripts/create_zip.sh` | Package signed `.app` → `Plumb-{ver}.zip` for OTA. | **Create** |
| `scripts/build_app.sh` | Expose VERSION to downstream scripts (already reads VERSION). | **Modify** (minor) |
| `scripts/publish_release.sh` | Upload zip asset + maintain `dist/appcast.json`. | **Modify** |
| `dist/appcast.json` | Version manifest (single latest-version record). | **Create** |
| `README.md` / `README.zh.md` | Document in-app updates. | **Modify** |

**TDD ordering:** Tasks 1–4 are pure logic with unit tests first. Task 5 (Coordinator) ties them together. Task 6 (Installer) is UI/privileged — tested manually. Task 7+ wires UI and scripts.

---

## Task 1: `AppVersion` (semver parse + compare)

**Files:**
- Create: `Sources/Plumb/AppVersion.swift`
- Create: `Tests/PlumbTests/AppVersionTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/PlumbTests/AppVersionTests.swift`:

```swift
import Testing
@testable import Plumb

@Suite("AppVersion")
struct AppVersionTests {

    // MARK: - Parsing

    @Test("parses major.minor.patch")
    func parsesThreeSegments() {
        let v = AppVersion(parsing: "1.2.3")
        #expect(v?.major == 1)
        #expect(v?.minor == 2)
        #expect(v?.patch == 3)
    }

    @Test("strips leading v")
    func stripsLeadingV() {
        #expect(AppVersion(parsing: "v1.0.5") == AppVersion(major: 1, minor: 0, patch: 5))
    }

    @Test("rejects non-numeric segments")
    func rejectsNonNumeric() {
        #expect(AppVersion(parsing: "1.0") == nil)
        #expect(AppVersion(parsing: "1.x.3") == nil)
        #expect(AppVersion(parsing: "") == nil)
        #expect(AppVersion(parsing: "latest") == nil)
    }

    // MARK: - Comparison (Comparable)

    @Test("patch bump is greater")
    func patchGreater() {
        #expect(AppVersion(major: 1, minor: 0, patch: 10) > AppVersion(major: 1, minor: 0, patch: 5))
    }

    @Test("minor beats patch")
    func minorBeatsPatch() {
        #expect(AppVersion(major: 1, minor: 2, patch: 0) > AppVersion(major: 1, minor: 1, patch: 9))
    }

    @Test("major beats minor")
    func majorBeatsMinor() {
        #expect(AppVersion(major: 2, minor: 0, patch: 0) > AppVersion(major: 1, minor: 9, patch: 9))
    }

    @Test("equal versions are equal")
    func equal() {
        #expect(AppVersion(major: 1, minor: 0, patch: 0) == AppVersion(major: 1, minor: 0, patch: 0))
    }

    @Test("newer version detection helper")
    func isNewerThan() {
        let current = AppVersion(major: 1, minor: 0, patch: 5)
        #expect(AppVersion(major: 1, minor: 0, patch: 6)!.isNewerThan(current))
        #expect(!AppVersion(major: 1, minor: 0, patch: 5)!.isNewerThan(current))   // equal → not newer
        #expect(!AppVersion(major: 1, minor: 0, patch: 4)!.isNewerThan(current))   // older → not newer
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppVersionTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'AppVersion' in scope` (type doesn't exist yet).

- [ ] **Step 3: Write the implementation**

`Sources/Plumb/AppVersion.swift`:

```swift
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppVersion
//
// 模块角色：语义化版本（major.minor.patch）的解析与比较，纯逻辑、无 IO。
//
// 职责：
//   - 从字符串（如 "1.0.5" 或 "v1.0.5"）解析为 AppVersion。
//   - 实现 Comparable，支持 OTA 的新旧版本比较（"只升不降"）。
//   - current：读取当前 .app 的 CFBundleShortVersionString 作为运行时版本。
//
// 设计说明：解析失败返回 nil，调用方据此把 appcast 的非法 version 视为"无更新"。
// ─────────────────────────────────────────────────────────────────────────────

/// 语义化版本。仅支持 major.minor.patch 三段数字（OTA 场景足够）。
struct AppVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// 从字符串解析；支持可选前导 'v'。非三段数字或含非数字字符则返回 nil。
    init?(parsing raw: String) {
        var s = raw
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let maj = Int(parts[0]),
              let min = Int(parts[1]),
              let pat = Int(parts[2]) else { return nil }
        self.init(major: maj, minor: min, patch: pat)
    }

    /// 当前运行 app 的版本（来自 CFBundleShortVersionString）。缺失或非法时返回 (0,0,0)。
    static var current: AppVersion {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return AppVersion(parsing: raw) ?? AppVersion(major: 0, minor: 0, patch: 0)
    }

    /// self 是否严格晚于 other（用于"只升不降"判断）。
    func isNewerThan(_ other: AppVersion) -> Bool {
        return self > other
    }

    // Comparable：按字典序逐段比较。
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppVersionTests 2>&1 | tail -20`
Expected: All `AppVersionTests` cases PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Plumb/AppVersion.swift Tests/PlumbTests/AppVersionTests.swift
git commit -m "feat(ota): AppVersion semver parse + compare"
```

---

## Task 2: `UpdateManifest` (appcast model)

**Files:**
- Create: `Sources/Plumb/UpdateManifest.swift`
- Create: `Tests/PlumbTests/UpdateManifestTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/PlumbTests/UpdateManifestTests.swift`:

```swift
import Testing
import Foundation
@testable import Plumb

@Suite("UpdateManifest")
struct UpdateManifestTests {

    private let fullJSON = #"""
    {
      "version": "1.0.6",
      "url": "https://example.com/Plumb-1.0.6.zip",
      "sha256": "abc123",
      "notes": { "en": "EN", "zh": "中文", "es": "ES", "fr": "FR", "ja": "JA" },
      "minOS": "26.0"
    }
    """#

    @Test("decodes all fields")
    func decodesAllFields() throws {
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(fullJSON.utf8))
        #expect(manifest.version == "1.0.6")
        #expect(manifest.url.absoluteString == "https://example.com/Plumb-1.0.6.zip")
        #expect(manifest.sha256 == "abc123")
        #expect(manifest.minOS == AppVersion(major: 26, minor: 0, patch: 0))
    }

    @Test("notes returns exact language when present")
    func notesExactLanguage() throws {
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(fullJSON.utf8))
        #expect(manifest.notes(for: .zh) == "中文")
        #expect(manifest.notes(for: .en) == "EN")
    }

    @Test("notes falls back to en when language missing")
    func notesFallbackEn() throws {
        let json = #"{"version":"1.0.6","url":"https://x/y.zip","sha256":"a","notes":{"en":"only"},"minOS":"26.0"}"#
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.notes(for: .zh) == "only")
        #expect(manifest.notes(for: .ja) == "only")
    }

    @Test("parsedVersion returns AppVersion for valid version")
    func parsedVersionValid() throws {
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(fullJSON.utf8))
        #expect(manifest.parsedVersion == AppVersion(major: 1, minor: 0, patch: 6))
    }

    @Test("parsedVersion returns nil for malformed version")
    func parsedVersionMalformed() throws {
        let json = #"{"version":"latest","url":"https://x/y.zip","sha256":"a","notes":{"en":"x"},"minOS":"26.0"}"#
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.parsedVersion == nil)
    }

    @Test("minOS defaults to 0.0.0 when absent")
    func minOSDefaultsToZero() throws {
        let json = #"{"version":"1.0.0","url":"https://x/y.zip","sha256":"a","notes":{"en":"x"}}"#
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.minOS == AppVersion(major: 0, minor: 0, patch: 0))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateManifestTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'UpdateManifest' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/Plumb/UpdateManifest.swift`:

```swift
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateManifest
//
// 模块角色：appcast.json 的数据模型（Codable）。
//
// 职责：
//   - 解码 appcast 的 version/url/sha256/notes/minOS 五个字段。
//   - notes(for:)：按当前 UI 语言取文案，缺失回退英语。
//   - parsedVersion / minOS：把字符串版本转成 AppVersion，非法时 nil / 0.0.0。
// ─────────────────────────────────────────────────────────────────────────────

/// appcast.json 模型。单条记录指向"最新版本"。
struct UpdateManifest: Codable {
    let version: String
    let url: URL
    let sha256: String
    let notes: [String: String]
    let minOS: AppVersion?

    enum CodingKeys: String, CodingKey {
        case version, url, sha256, notes
        case minOS
    }

    init(version: String, url: URL, sha256: String, notes: [String: String], minOS: AppVersion?) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.notes = notes
        self.minOS = minOS
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(String.self, forKey: .version)
        self.url = try c.decode(URL.self, forKey: .url)
        self.sha256 = try c.decode(String.self, forKey: .sha256)
        self.notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
        let minOSRaw = try c.decodeIfPresent(String.self, forKey: .minOS)
        self.minOS = minOSRaw.flatMap { AppVersion(parsing: $0) }
    }

    /// 把 version 字段解析为 AppVersion；非法时返回 nil（调用方视为"无更新"）。
    var parsedVersion: AppVersion? {
        AppVersion(parsing: version)
    }

    /// 按语言取 release notes；缺失回退英语，英语也缺失返回空串。
    func notes(for language: AppLanguage) -> String {
        let code = languageCode(for: language)
        if let v = notes[code] { return v }
        return notes["en"] ?? ""
    }

    private func languageCode(for language: AppLanguage) -> String {
        switch language {
        case .zh: return "zh"
        case .en: return "en"
        case .es: return "es"
        case .fr: return "fr"
        case .ja: return "ja"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdateManifestTests 2>&1 | tail -20`
Expected: All `UpdateManifestTests` cases PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Plumb/UpdateManifest.swift Tests/PlumbTests/UpdateManifestTests.swift
git commit -m "feat(ota): UpdateManifest appcast model + localized notes"
```

---

## Task 3: `UpdateChecker` (fetch + compare + minOS gate)

**Files:**
- Create: `Sources/Plumb/UpdateChecker.swift`
- Create: `Tests/PlumbTests/UpdateCheckerTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/PlumbTests/UpdateCheckerTests.swift`:

```swift
import Testing
import Foundation
@testable import Plumb

@Suite("UpdateChecker")
struct UpdateCheckerTests {

    /// 固定返回给定 Data 的 fetcher，用于注入（测试不触网）。
    private struct MockFetcher: ManifestFetcher {
        let data: Data?
        let error: Error?
        func fetch() async throws -> Data {
            if let error { throw error }
            return data ?? Data()
        }
    }

    struct StubError: Error {}

    private func manifestJSON(version: String, minOS: String = "0.0.0") -> String {
        return #"{"version":"\#(version)","url":"https://x/y.zip","sha256":"a","notes":{"en":"n"},"minOS":"\#(minOS)"}"#
    }

    @Test("returns upToDate when manifest version equals current")
    func upToDate() async throws {
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data(manifestJSON(version: "1.0.0").utf8)))
        let result = try await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: .init(major: 26, minor: 0, patch: 0))
        guard case .upToDate = result else { Issue.record("expected upToDate"); return }
    }

    @Test("returns available when manifest version is newer")
    func available() async throws {
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data(manifestJSON(version: "1.0.6").utf8)))
        let result = try await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: .init(major: 26, minor: 0, patch: 0))
        guard case .available(let m) = result else { Issue.record("expected available"); return }
        #expect(m.version == "1.0.6")
    }

    @Test("treats older manifest version as upToDate (only-up) ")
    func onlyUp() async throws {
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data(manifestJSON(version: "0.9.0").utf8)))
        let result = try await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: .init(major: 26, minor: 0, patch: 0))
        guard case .upToDate = result else { Issue.record("older version should be upToDate"); return }
    }

    @Test("treats malformed manifest version as upToDate")
    func malformedVersion() async throws {
        let json = #"{"version":"latest","url":"https://x/y.zip","sha256":"a","notes":{"en":"n"},"minOS":"0.0.0"}"#
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data(json.utf8)))
        let result = try await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: .init(major: 26, minor: 0, patch: 0))
        guard case .upToDate = result else { Issue.record("malformed should be upToDate"); return }
    }

    @Test("returns osTooOld when minOS exceeds running OS")
    func osTooOld() async throws {
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data(manifestJSON(version: "2.0.0", minOS: "27.0").utf8)))
        let result = try await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: .init(major: 26, minor: 0, patch: 0))
        guard case .osTooOld = result else { Issue.record("expected osTooOld"); return }
    }

    @Test("returns error when fetcher throws")
    func fetchError() async throws {
        let checker = UpdateChecker(fetcher: MockFetcher(data: nil, error: StubError()))
        let result = try await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: .init(major: 26, minor: 0, patch: 0))
        guard case .error = result else { Issue.record("expected error"); return }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ManifestFetcher' / 'UpdateChecker' / 'UpdateResult' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/Plumb/UpdateChecker.swift`:

```swift
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateChecker
//
// 模块角色：拉取 appcast 并判断是否有可用更新。
//
// 职责：
//   - 通过注入的 ManifestFetcher 获取 appcast 字节（生产 URLSession，测试 Mock）。
//   - 解码为 UpdateManifest。
//   - 版本比较（只升不降）+ minOS 门槛判断。
//   - 返回 UpdateResult，供 Coordinator 决定是否提示用户。
//
// 设计说明：网络抽到 ManifestFetcher 协议，使本组件可纯单测（不触网）。
// ─────────────────────────────────────────────────────────────────────────────

/// appcast 字节来源抽象。生产用 URLSessionManifestFetcher，测试用 Mock。
protocol ManifestFetcher {
    func fetch() async throws -> Data
}

/// 检查结果。
enum UpdateResult {
    case upToDate                       // 无更新（含降级、版本相等、manifest 版本非法）
    case available(UpdateManifest)      // 有更新且本机满足 minOS
    case osTooOld(UpdateManifest)       // 有更新但本机系统低于 minOS（调用方静默）
    case error                          // 网络错误 / appcast 解析失败
}

/// appcast URL（随发版提交到 repo main 分支）。
enum UpdateConfig {
    static let appcastURL = URL(string: "https://raw.githubusercontent.com/Lv-0/plumb/main/dist/appcast.json")!
}

/// 生产环境 fetcher：URLSession 拉取 appcast。
struct URLSessionManifestFetcher: ManifestFetcher {
    let url: URL
    init(url: URL = UpdateConfig.appcastURL) { self.url = url }
    func fetch() async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

struct UpdateChecker {
    let fetcher: ManifestFetcher

    init(fetcher: ManifestFetcher = URLSessionManifestFetcher()) {
        self.fetcher = fetcher
    }

    /// 检查更新。current=当前 app 版本；osVersion=本机系统版本（用于 minOS 门槛）。
    func check(current: AppVersion, osVersion: AppVersion) async throws -> UpdateResult {
        let data: Data
        do {
            data = try await fetcher.fetch()
        } catch {
            return .error
        }
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            return .error
        }
        // manifest 版本非法 → 视为无更新（静默）。
        guard let remote = manifest.parsedVersion else { return .upToDate }
        // 只升不降。
        guard remote.isNewerThan(current) else { return .upToDate }
        // minOS 门槛：本机低于要求 → 不提示（静默）。
        if let minOS = manifest.minOS, osVersion < minOS {
            return .osTooOld(manifest)
        }
        return .available(manifest)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdateCheckerTests 2>&1 | tail -20`
Expected: All `UpdateCheckerTests` cases PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Plumb/UpdateChecker.swift Tests/PlumbTests/UpdateCheckerTests.swift
git commit -m "feat(ota): UpdateChecker fetch + compare + minOS gate"
```

---

## Task 4: `UpdateDownloader` (download + sha256 + unzip)

**Files:**
- Create: `Sources/Plumb/UpdateDownloader.swift`
- Create: `Tests/PlumbTests/UpdateDownloaderTests.swift`

- [ ] **Step 1: Write the failing tests (sha256 verify only — download/unzip are integration-tested manually)**

`Tests/PlumbTests/UpdateDownloaderTests.swift`:

```swift
import Testing
import Foundation
import CryptoKit
@testable import Plumb

@Suite("UpdateDownloader")
struct UpdateDownloaderTests {

    @Test("verifySHA256 passes for matching digest")
    func verifyPasses() throws {
        let bytes = Data("hello plumb".utf8)
        let digest = SHA256.hash(data: bytes).compactMap { String(format: "%02x", $0) }.joined()
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: digest) == true)
    }

    @Test("verifySHA256 fails for mismatched digest")
    func verifyFails() throws {
        let bytes = Data("hello plumb".utf8)
        let wrong = String(repeating: "0", count: 64)
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: wrong) == false)
    }

    @Test("verifySHA256 fails for malformed hex")
    func verifyMalformedHex() throws {
        let bytes = Data("x".utf8)
        #expect(UpdateDownloader.verifySHA256(data: bytes, expectedHex: "nothex") == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateDownloaderTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'UpdateDownloader' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/Plumb/UpdateDownloader.swift`:

```swift
import Foundation
import CryptoKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateDownloader
//
// 模块角色：下载更新包并校验完整性。
//
// 职责：
//   - 下载 zip 到临时文件。
//   - sha256 校验（防损坏/截断）。
//   - 解压到临时目录，返回其中 Plumb.app 的路径。
//
// 设计说明：下载/解压涉及网络与磁盘，端到端在手动验证里覆盖；
// sha256 校验是纯逻辑，单测覆盖。
// ─────────────────────────────────────────────────────────────────────────────

/// 下载阶段失败原因（Coordinator 据此生成用户文案）。
enum DownloadError: Error {
    case downloadFailed(underlying: Error)
    case sha256Mismatch
    case unzipFailed
    case appNotFoundInArchive
}

struct UpdateDownloader {
    /// 校验 Data 的 sha256 是否等于预期十六进制串（小写）。非法 hex 或不匹配返回 false。
    static func verifySHA256(data: Data, expectedHex: String) -> Bool {
        let digest = SHA256.hash(data: data)
        let actual = digest.compactMap { String(format: "%02x", $0) }.joined()
        return actual.lowercased() == expectedHex.lowercased()
    }

    /// 下载 url 到临时文件，返回文件 URL。
    func download(from url: URL) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: tmp)
            return tmp
        } catch {
            throw DownloadError.downloadFailed(underlying: error)
        }
    }

    /// 校验临时文件 sha256 与 expectedHex 匹配；不匹配抛 sha256Mismatch。
    func verify(file: URL, expectedHex: String) throws {
        let data = try Data(contentsOf: file)
        guard Self.verifySHA256(data: data, expectedHex: expectedHex) else {
            throw DownloadError.sha256Mismatch
        }
    }

    /// 解压 zip 到新临时目录，返回其中的 Plumb.app 路径。失败抛 unzipFailed / appNotFoundInArchive。
    func unzip(_ zip: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", zip.path, "-d", dest.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw DownloadError.unzipFailed
        }
        guard proc.terminationStatus == 0 else { throw DownloadError.unzipFailed }
        let app = dest.appendingPathComponent("Plumb.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw DownloadError.appNotFoundInArchive
        }
        return app
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdateDownloaderTests 2>&1 | tail -20`
Expected: All `UpdateDownloaderTests` cases PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Plumb/UpdateDownloader.swift Tests/PlumbTests/UpdateDownloaderTests.swift
git commit -m "feat(ota): UpdateDownloader download + sha256 verify + unzip"
```

---

## Task 5: `UpdateCoordinator` (orchestration)

**Files:**
- Create: `Sources/Plumb/UpdateCoordinator.swift`

This task ties Tasks 1–4 together and is exercised by the manual end-to-end test (Task 9). It depends on macOS AppKit (NSAlert, NSWorkspace), so it has no unit test here — its logic parts (checker/downloader) are already unit-tested in isolation.

- [ ] **Step 1: Write the implementation**

`Sources/Plumb/UpdateCoordinator.swift`:

```swift
import Foundation
import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateCoordinator
//
// 模块角色：OTA 流程编排者，主 app 的唯一入口。
//
// 职责：
//   - 后台静默检查（启动时，失败静默）。
//   - 手动检查（用户点菜单，失败弹窗）。
//   - 检测到更新 → 展示版本信息 → 用户确认 → 下载 → sha256 校验 →
//     写 installerMode 标志 + 待安装路径 → 以 Launch Services 重开自身进入安装器。
//
// 设计说明：主 app 永不提权、不碰 /Applications；替换职责交给安装器进程。
// ─────────────────────────────────────────────────────────────────────────────

/// installer 模式从 UserDefaults 读取的待安装 app 路径 key。
enum UpdateConfig {
    static let installerModeKey = "installerMode"
    static let installerAppPathKey = "installerAppPath"
    /// 后台检查最小间隔（秒），避免每次启动都请求。
    static let backgroundCheckMinInterval: TimeInterval = 6 * 3600
    static let lastCheckKey = "otaLastCheckTimestamp"
}

final class UpdateCoordinator {
    static let shared = UpdateCoordinator()

    private let checker = UpdateChecker()
    private let downloader = UpdateDownloader()

    private var osVersion: AppVersion {
        // 从系统版本字符串（如 "26.0" / "26.1"）取前两段。
        let raw = ProcessInfo.processInfo.operatingSystemVersion
        return AppVersion(major: raw.majorVersion, minor: raw.minorVersion, patch: raw.patchVersion)
    }

    /// 启动后台静默检查。失败完全静默（不打扰）。
    func checkForUpdatesInBackground() {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: UpdateConfig.lastCheckKey) as? Double,
           Date().timeIntervalSince1970 - last < UpdateConfig.backgroundCheckMinInterval {
            return // 节流：距离上次检查不足间隔，跳过。
        }
        defaults.set(Date().timeIntervalSince1970, forKey: UpdateConfig.lastCheckKey)

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.checker.check(current: AppVersion.current, osVersion: self.osVersion)
                await MainActor.run {
                    if case .available(let manifest) = result {
                        self.notifyAvailable(manifest: manifest, silent: true)
                    }
                }
            } catch {
                // 后台失败静默。
            }
        }
    }

    /// 手动检查。失败弹窗提示（不阻塞 app）。
    func checkForUpdatesManually() {
        Task { [weak self] in
            guard let self else { return }
            let result = try await self.checker.check(current: AppVersion.current, osVersion: self.osVersion)
            await MainActor.run {
                switch result {
                case .available(let manifest):
                    self.notifyAvailable(manifest: manifest, silent: false)
                case .upToDate, .osTooOld:
                    if result == .upToDate {
                        self.alert(title: L10n.otaUpToDate, message: "")
                    }
                    // osTooOld 静默（手动也不提示无法安装的版本）。
                case .error:
                    self.alert(title: L10n.otaCheckFailed, message: L10n.otaCheckFailedHint)
                }
            }
        }
    }

    /// 展示"有新版本"提示，用户确认后走完整下载+安装流程。
    private func notifyAvailable(manifest: UpdateManifest, silent: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(format: L10n.otaNewVersionTitle, manifest.version)
        alert.informativeText = manifest.notes(for: AppLanguage.current)
        alert.addButton(withTitle: L10n.otaUpdateNow)
        alert.addButton(withTitle: L10n.otaCancel)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return } // 用户取消
        startUpdate(manifest: manifest)
    }

    /// 下载 → 校验 → 解压 → 写标志 → 重开自身进入安装器。
    private func startUpdate(manifest: UpdateManifest) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let zip = try await self.downloader.download(from: manifest.url)
                try self.downloader.verify(file: zip, expectedHex: manifest.sha256)
                let newApp = try self.downloader.unzip(zip)
                await MainActor.run {
                    self.relaunchIntoInstaller(with: newApp)
                }
            } catch {
                await MainActor.run {
                    self.alert(title: L10n.otaDownloadFailed, message: L10n.otaDownloadFailedHint)
                }
            }
        }
    }

    /// 写 installerMode + 待安装路径，以 Launch Services 重开自身，然后退出当前进程。
    private func relaunchIntoInstaller(with newApp: URL) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: UpdateConfig.installerModeKey)
        defaults.set(newApp.path, forKey: UpdateConfig.installerAppPathKey)
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        NSApp.terminate(nil)
    }

    private func alert(title: String, message: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -15`
Expected: `Build complete!` (L10n OTA keys referenced here don't exist yet — they're added in Task 7. To keep this task independently compilable, **run Task 7 (Localization) before this step**, OR temporarily stub the `L10n.ota*` accessors. Recommended ordering: implement Task 7 right after Task 4, then this Task 5.)

> **Reorder note:** Task 7 (Localization) has no test dependency and should be done before Task 5's compile step. If executing in order, do Task 5 Step 1 (write code), then Task 7, then return to Task 5 Step 2 (compile).

- [ ] **Step 3: Commit**

```bash
git add Sources/Plumb/UpdateCoordinator.swift
git commit -m "feat(ota): UpdateCoordinator orchestration (check→prompt→download→relaunch)"
```

---

## Task 6: `UpdateInstaller` (privileged atomic replace + relaunch)

**Files:**
- Create: `Sources/Plumb/UpdateInstaller.swift`

This is UI + privileged I/O — no unit test; covered by manual end-to-end (Task 9). It uses `AuthorizationCopyRights` to run a constrained `rm` + `cp -R` against `/Applications/Plumb.app`.

- [ ] **Step 1: Write the implementation**

`Sources/Plumb/UpdateInstaller.swift`:

```swift
import Foundation
import AppKit
import Security.Authorization
import Security.AuthorizationTags

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateInstaller
//
// 模块角色：安装器模式入口（installerMode 标志触发）。
//
// 职责：
//   - 极简 NSWindow 显示进度。
//   - AuthorizationCopyRights 提权执行 rm + cp -R 原子替换 /Applications/Plumb.app。
//   - 清零 installerMode 标志，以 Launch Services 启动新版本。
//
// 设计说明：主 app 退出后由本进程完成替换，避免"运行中二进制被覆盖"。
// 替换前 newApp 已通过 sha256 校验（由 Coordinator 保证）。
// ─────────────────────────────────────────────────────────────────────────────

enum InstallError: Error {
    case missingAppPath
    case authorizationDenied
    case replaceFailed(status: Int32)
    case relaunchFailed
}

final class UpdateInstallerDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var statusLabel: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow()
        runInstall()
    }

    private func setupWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = L10n.otaInstallingTitle
        let label = NSTextField(labelWithString: L10n.otaInstallingMessage)
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 40, width: 320, height: 40)
        w.contentView?.addSubview(label)
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        statusLabel = label
    }

    private func runInstall() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.performInstall()
                DispatchQueue.main.async {
                    self?.finishAndRelaunch()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.fail(with: error)
                }
            }
        }
    }

    /// 提权原子替换 /Applications/Plumb.app。
    private func performInstall() throws {
        let defaults = UserDefaults.standard
        guard let srcPath = defaults.string(forKey: UpdateConfig.installerAppPathKey),
              FileManager.default.fileExists(atPath: srcPath) else {
            throw InstallError.missingAppPath
        }
        let dest = "/Applications/Plumb.app"
        // 用 Authorization 提权执行：rm -rf 旧 + cp -R 新。命令固定，不接受用户输入路径。
        let script = "rm -rf '\(dest)' && cp -R '\(srcPath)' '\(dest)'"
        let status = try runPrivileged(shellScript: script)
        guard status == 0 else { throw InstallError.replaceFailed(status: status) }
    }

    /// 通过 AuthorizationCopyRights 提权执行 shell 命令。用户取消则抛 authorizationDenied。
    /// 返回 0 表示授权与执行成功（注意：AEWP 不回传子进程 exit code，故成功=0；授权失败抛错）。
    private func runPrivileged(shellScript: String) throws -> Int32 {
        var auth: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
        let os = AuthorizationCreate(nil, nil, flags, &auth)
        guard os == errAuthorizationSuccess, let authRef = auth else {
            throw InstallError.authorizationDenied
        }
        defer { AuthorizationFree(authRef, []) }

        let args: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup(shellScript)]
        defer { args.forEach { if let p = $0 { free(p) } } }

        // 提取 new app 路径后立即清零标志（无论后续成败，避免残留并防止重复进入安装器）。
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: UpdateConfig.installerModeKey)
        defaults.removeObject(forKey: UpdateConfig.installerAppPathKey)

        let execStatus = AuthorizationExecuteWithPrivileges(
            authRef, "/bin/sh", flags, args, nil
        )
        guard execStatus == errAuthorizationSuccess else {
            throw InstallError.authorizationDenied
        }
        return 0
    }

    private func finishAndRelaunch() {
        statusLabel?.stringValue = L10n.otaInstallDone
        let dest = URL(fileURLWithPath: "/Applications/Plumb.app")
        NSWorkspace.shared.openApplication(at: dest, configuration: .init()) { _, _ in
            exit(0)
        }
    }

    private func fail(with error: Error) {
        let msg: String
        switch error {
        case InstallError.authorizationDenied: msg = L10n.otaInstallCanceled
        default: msg = L10n.otaInstallFailed
        }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = msg
        a.addButton(withTitle: "OK")
        a.runModal()
        exit(1)
    }
}
```

> **Note on `AuthorizationExecuteWithPrivileges`:** it is deprecated in recent SDKs but still functional and is the simplest path for a single-app installer without a separate helper tool. If it produces deprecation errors that block the build, the acceptable fallback (documented in the spec's follow-up) is to write the new app to a temp location and use `NSWorkspace` to open it with an `AppleScript`-based `do shell script ... with administrator privileges`. Prefer the Authorization API path first; only switch if the build fails.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!` (requires Task 7 Localization keys; do Task 7 first if not done).

- [ ] **Step 3: Commit**

```bash
git add Sources/Plumb/UpdateInstaller.swift
git commit -m "feat(ota): UpdateInstaller privileged atomic replace + relaunch"
```

---

## Task 7: Localization — add OTA keys

**Files:**
- Modify: `Sources/Plumb/Localization.swift`

- [ ] **Step 1: Add keys to the `Key` enum (after `errUnableToWriteWindowPosition`)**

In the `enum Key` block, add:

```swift
        // OTA 更新
        case otaCheckForUpdates
        case otaUpToDate
        case otaCheckFailed
        case otaCheckFailedHint
        case otaNewVersionTitle
        case otaUpdateNow
        case otaCancel
        case otaDownloadFailed
        case otaDownloadFailedHint
        case otaInstallingTitle
        case otaInstallingMessage
        case otaInstallDone
        case otaInstallCanceled
        case otaInstallFailed
```

- [ ] **Step 2: Add strings to ALL FIVE language tables (`.en`, `.es`, `.fr`, `.zh`, `.ja`)**

Add to `.en` table:

```swift
            .otaCheckForUpdates: "Check for Updates…",
            .otaUpToDate: "You're up to date.",
            .otaCheckFailed: "Update check failed.",
            .otaCheckFailedHint: "Check your network connection and try again.",
            .otaNewVersionTitle: "Plumb %@ is available",
            .otaUpdateNow: "Update Now",
            .otaCancel: "Cancel",
            .otaDownloadFailed: "Download failed.",
            .otaDownloadFailedHint: "The update package may be damaged. Try again later or download manually from GitHub.",
            .otaInstallingTitle: "Installing Update",
            .otaInstallingMessage: "Replacing Plumb…",
            .otaInstallDone: "Done. Relaunching…",
            .otaInstallCanceled: "Installation canceled. The previous version was kept.",
            .otaInstallFailed: "Installation failed. The previous version was kept.",
```

Add to `.zh` table:

```swift
            .otaCheckForUpdates: "检查更新…",
            .otaUpToDate: "已是最新版本。",
            .otaCheckFailed: "检查更新失败。",
            .otaCheckFailedHint: "请检查网络连接后重试。",
            .otaNewVersionTitle: "Plumb %@ 已发布",
            .otaUpdateNow: "立即更新",
            .otaCancel: "取消",
            .otaDownloadFailed: "下载失败。",
            .otaDownloadFailedHint: "更新包可能已损坏。请稍后重试，或前往 GitHub 手动下载。",
            .otaInstallingTitle: "正在安装更新",
            .otaInstallingMessage: "正在替换 Plumb…",
            .otaInstallDone: "完成，正在重启…",
            .otaInstallCanceled: "安装已取消，已保留原版本。",
            .otaInstallFailed: "安装失败，已保留原版本。",
```

Add to `.es` table:

```swift
            .otaCheckForUpdates: "Buscar actualizaciones…",
            .otaUpToDate: "Ya tienes la última versión.",
            .otaCheckFailed: "Error al comprobar actualizaciones.",
            .otaCheckFailedHint: "Comprueba tu conexión de red e inténtalo de nuevo.",
            .otaNewVersionTitle: "Plumb %@ está disponible",
            .otaUpdateNow: "Actualizar ahora",
            .otaCancel: "Cancelar",
            .otaDownloadFailed: "Error en la descarga.",
            .otaDownloadFailedHint: "El paquete puede estar dañado. Inténtalo más tarde o descárgalo manualmente desde GitHub.",
            .otaInstallingTitle: "Instalando actualización",
            .otaInstallingMessage: "Reemplazando Plumb…",
            .otaInstallDone: "Listo. Reiniciando…",
            .otaInstallCanceled: "Instalación cancelada. Se mantuvo la versión anterior.",
            .otaInstallFailed: "Error en la instalación. Se mantuvo la versión anterior.",
```

Add to `.fr` table:

```swift
            .otaCheckForUpdates: "Rechercher des mises à jour…",
            .otaUpToDate: "Vous êtes à jour.",
            .otaCheckFailed: "Échec de la vérification des mises à jour.",
            .otaCheckFailedHint: "Vérifiez votre connexion réseau et réessayez.",
            .otaNewVersionTitle: "Plumb %@ est disponible",
            .otaUpdateNow: "Mettre à jour",
            .otaCancel: "Annuler",
            .otaDownloadFailed: "Échec du téléchargement.",
            .otaDownloadFailedHint: "Le paquet est peut-être endommagé. Réessayez plus tard ou téléchargez-le manuellement depuis GitHub.",
            .otaInstallingTitle: "Installation de la mise à jour",
            .otaInstallingMessage: "Remplacement de Plumb…",
            .otaInstallDone: "Terminé. Redémarrage…",
            .otaInstallCanceled: "Installation annulée. La version précédente a été conservée.",
            .otaInstallFailed: "Échec de l'installation. La version précédente a été conservée.",
```

Add to `.ja` table:

```swift
            .otaCheckForUpdates: "更新を確認…",
            .otaUpToDate: "最新です。",
            .otaCheckFailed: "更新の確認に失敗しました。",
            .otaCheckFailedHint: "ネットワーク接続を確認して再試行してください。",
            .otaNewVersionTitle: "Plumb %@ が利用可能です",
            .otaUpdateNow: "今すぐ更新",
            .otaCancel: "キャンセル",
            .otaDownloadFailed: "ダウンロードに失敗しました。",
            .otaDownloadFailedHint: "パッケージが破損している可能性があります。後で再試行するか、GitHub から手動でダウンロードしてください。",
            .otaInstallingTitle: "更新をインストール中",
            .otaInstallingMessage: "Plumb を置き換えています…",
            .otaInstallDone: "完了。再起動中…",
            .otaInstallCanceled: "インストールがキャンセルされました。以前のバージョンを維持します。",
            .otaInstallFailed: "インストールに失敗しました。以前のバージョンを維持します。",
```

- [ ] **Step 3: Add accessors (after `errUnableToWriteWindowPosition` accessor)**

```swift
    static var otaCheckForUpdates: String { tr(.otaCheckForUpdates) }
    static var otaUpToDate: String { tr(.otaUpToDate) }
    static var otaCheckFailed: String { tr(.otaCheckFailed) }
    static var otaCheckFailedHint: String { tr(.otaCheckFailedHint) }
    static var otaNewVersionTitle: String { tr(.otaNewVersionTitle) }
    static var otaUpdateNow: String { tr(.otaUpdateNow) }
    static var otaCancel: String { tr(.otaCancel) }
    static var otaDownloadFailed: String { tr(.otaDownloadFailed) }
    static var otaDownloadFailedHint: String { tr(.otaDownloadFailedHint) }
    static var otaInstallingTitle: String { tr(.otaInstallingTitle) }
    static var otaInstallingMessage: String { tr(.otaInstallingMessage) }
    static var otaInstallDone: String { tr(.otaInstallDone) }
    static var otaInstallCanceled: String { tr(.otaInstallCanceled) }
    static var otaInstallFailed: String { tr(.otaInstallFailed) }
```

- [ ] **Step 4: Run existing Localization completeness test to verify all 5 tables have all keys**

Run: `swift test --filter LocalizationTests 2>&1 | tail -15`
Expected: PASS — the existing "every key is present and non-empty in every supported language" test validates the new keys are in all 5 tables. If it FAILS, a table is missing a key — add it.

- [ ] **Step 5: Now compile Tasks 5 & 6 (they reference these keys)**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Plumb/Localization.swift
git commit -m "feat(l10n): add OTA update keys (en/es/fr/zh/ja)"
```

---

## Task 8: Wire `main.swift` installer-mode branch + `AppDelegate` menu/background check

**Files:**
- Modify: `Sources/Plumb/main.swift` (insert installer branch after self-test branches, before `let delegate = AppDelegate()`)
- Modify: `Sources/Plumb/AppDelegate.swift` (add menu item + background check)

- [ ] **Step 1: Add installer-mode branch to `main.swift`**

Insert immediately before `let delegate = AppDelegate()` (currently line 121):

```swift
// Installer mode: triggered when the normal-mode app writes installerMode=true and
// relaunches itself. Runs a minimal privileged installer that replaces
// /Applications/Plumb.app, then relaunches the new version.
if UserDefaults.standard.bool(forKey: "installerMode") {
    UserDefaults.standard.set(false, forKey: "installerMode")  // cleared here too for safety
    app.setActivationPolicy(.regular)
    app.delegate = UpdateInstallerDelegate()
    app.run()
    exit(0)
}
```

- [ ] **Step 2: Add "Check for Updates…" menu item + background check to `AppDelegate.swift`**

In the status bar menu builder (the function building the menu with `centerNow` / `settings` items — around line 128–164), add an update item before the settings item. Insert before the `menu.addItem(.separator())` that precedes the settings item, OR right after the settings item block. Place it right after the `settingsItem` block (after line 146 `settingsItem.image = ...`):

```swift
        menu.addItem(.separator())
        let updateItem = menu.addItem(withTitle: L10n.otaCheckForUpdates, action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
```

Add the action method to the `AppDelegate` class (next to other `@objc` methods like `openSettings`):

```swift
    @objc private func checkForUpdates() {
        UpdateCoordinator.shared.checkForUpdatesManually()
    }
```

Add the background check at the **end** of `applicationDidFinishLaunching` (after existing setup):

```swift
        UpdateCoordinator.shared.checkForUpdatesInBackground()
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 4: Run full test suite to ensure no regressions**

Run: `swift test 2>&1 | tail -10`
Expected: all tests PASS (existing 51 + new OTA tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Plumb/main.swift Sources/Plumb/AppDelegate.swift
git commit -m "feat(ota): wire installer-mode branch + Check for Updates menu item"
```

---

## Task 9: Manual end-to-end verification

**This is the core success criterion (spec §9).** Requires a Mac desktop session. Steps marked 👤 need the human.

**Files:** none (verification only)

- [ ] **Step 1: Build the app (ensure stable signing cert from the signing-fix work is present so TCC persists)**

👤 Ensure `scripts/make_signing_cert.sh` has been run once (cert trusted).
Run: `scripts/build_app.sh 2>&1 | tail -5`
Expected: prints `签名身份: Plumb Local Signer（稳定…）`. If cert not present, the permission-preservation part of this test cannot be verified — pause and run `make_signing_cert.sh` first.

- [ ] **Step 2: Stage a fake "newer" appcast so the installed (older) version sees an update**

The installed app is the current version (e.g. 1.0.x). Create a test appcast that claims a newer version pointing at a freshly-built zip. Temporarily point the app at a local appcast by overriding `UpdateConfig.appcastURL` is not ideal — instead, build a zip of the same code but with a bumped VERSION, host the appcast + zip locally.

👤 Steps:
1. Edit `scripts/build_app.sh` `VERSION="1.0.99"` (test version higher than installed).
2. `scripts/build_app.sh && scripts/create_zip.sh` → produces `dist/Plumb-1.0.99.zip`.
3. Compute sha256: `shasum -a 256 dist/Plumb-1.0.99.zip` and note the hash.
4. Write a local appcast to a temp HTTP-served dir or use a `python3 -m http.server` serving a folder with `appcast.json` + the zip, with `version:"1.0.99"`, correct url + sha256.
5. Temporarily change `UpdateConfig.appcastURL` to the local URL, rebuild the **installed** (older-version) app, install it.

- [ ] **Step 3: Verify detection + prompt (👤)**

👤 Launch the older installed Plumb → open menu → "Check for Updates…".
Expected: alert "Plumb 1.0.99 is available" with the zh/en notes.

- [ ] **Step 4: Verify download + install flow (👤)**

👤 Click "Update Now".
Expected: downloads → sha256 passes → main app quits → installer window appears → system password prompt → after auth, `/Applications/Plumb.app` is replaced → relaunch.

- [ ] **Step 5: Verify version changed (👤)**

👤 Launch the (now updated) Plumb → "Check for Updates…" → "You're up to date."

- [ ] **Step 6: Verify permissions persisted (the decisive check, depends on stable signing)**

👤 Open Settings → Privacy & Security → Accessibility & Screen Recording.
Expected: Plumb still listed and enabled — **no re-grant needed**. This is the OTA + signing-fix combined value.

- [ ] **Step 7: Revert the test VERSION bump**

Revert `VERSION` in `build_app.sh` back to the real release version before packaging (Task 11).

---

## Task 10: `scripts/create_zip.sh`

**Files:**
- Create: `scripts/create_zip.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Package the signed dist/Plumb.app into dist/Plumb-{VERSION}.zip for OTA.
# The zip mirrors build_app.sh's VERSION and the same signed .app the DMG ships.
set -euo pipefail

APP_DIR="dist/Plumb.app"
VERSION="${VERSION:-1.0.0}"
ZIP_PATH="dist/Plumb-${VERSION}.zip"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "未找到 ${APP_DIR}，请先运行 scripts/build_app.sh"
  exit 1
fi

rm -f "${ZIP_PATH}"
# ditto preserves resource forks / extended attrs / code signature for .app bundles.
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo "已生成: ${ZIP_PATH}"
echo "sha256: $(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
```

- [ ] **Step 2: Make executable + syntax-check**

Run: `chmod +x scripts/create_zip.sh && bash -n scripts/create_zip.sh && echo OK`
Expected: `OK`.

- [ ] **Step 3: Test it produces a valid signed zip**

Run: `scripts/build_app.sh && scripts/create_zip.sh`
Expected: prints `已生成: dist/Plumb-1.0.0.zip` and a sha256.

Verify the zipped app is still signed and stable-identity (NOT cdhash):
Run: `unzip -o -q dist/Plumb-1.0.0.zip -d /tmp/zipcheck && scripts/verify_signing_identity.sh /tmp/zipcheck/Plumb.app; echo "EXIT=$?"; rm -rf /tmp/zipcheck`
Expected: `EXIT=0` with stable DR (depends on cert being present; if ad-hoc fallback, it'll be cdhash — acceptable for the script test, but release packaging must have the cert).

- [ ] **Step 4: Commit**

```bash
git add scripts/create_zip.sh
git commit -m "feat(release): create_zip.sh for OTA update packages"
```

---

## Task 11: `scripts/build_app.sh` — expose VERSION, `publish_release.sh` — upload zip + appcast, `dist/appcast.json`

**Files:**
- Modify: `scripts/build_app.sh` (ensure VERSION is exported/used downstream)
- Modify: `scripts/publish_release.sh`
- Create: `dist/appcast.json`

- [ ] **Step 1: Confirm VERSION flows from build_app.sh to create_zip.sh**

`build_app.sh` reads `VERSION="${VERSION:-1.0.0}"`. `create_zip.sh` reads the same. They share the env var when invoked in the same shell. No change needed if publish script invokes both in one shell. Verify by reading: `grep VERSION scripts/build_app.sh scripts/create_zip.sh`.

- [ ] **Step 2: Create the initial `dist/appcast.json`**

```json
{
  "version": "1.0.6",
  "url": "https://github.com/Lv-0/plumb/releases/download/v1.0.6/Plumb-1.0.6.zip",
  "sha256": "REPLACE_AT_RELEASE_TIME",
  "notes": {
    "en": "In-app updates + permissions now survive updates.",
    "zh": "软件内更新 + 权限现在可跨更新保留。",
    "es": "Actualizaciones desde la app y los permisos ya se conservan entre actualizaciones.",
    "fr": "Mises à jour depuis l'app et les permissions sont désormais conservées entre les mises à jour.",
    "ja": "アプリ内アップデートと、アップデート後も権限が維持されるようになりました。"
  },
  "minOS": "26.0"
}
```

> The `sha256` is computed at release time from the built zip (`shasum -a 256 dist/Plumb-1.0.6.zip`) and filled in before publish. Keep `version`/`url` in sync with the actual release tag.

- [ ] **Step 3: Update `publish_release.sh` to also upload the zip and to commit the appcast**

Read current `publish_release.sh`, then:
1. Add a second asset upload block for `dist/Plumb-${VERSION}.zip` (mirror the existing DMG upload logic with a different `ASSET_NAME`).
2. After upload, `git add dist/appcast.json && git commit && git push` so the appcast on `main` reflects the new release (the app reads it from `raw.githubusercontent.com/.../main/dist/appcast.json`).

Specifically, after the existing DMG upload (around `[3/3] Upload asset`), add:

```bash
echo "[4/5] Upload zip asset: Plumb-${VERSION}.zip"
ZIP_ASSET="dist/Plumb-${VERSION}.zip"
ZIP_NAME="$(basename "${ZIP_ASSET}")"
# (reuse the existing asset-upload helper pattern: delete existing if any, then upload)
existing_zip_id="$(echo "${assets}" | jq -r ".[] | select(.name==\"${ZIP_NAME}\") | .id" | head -n 1)"
if [[ -n "${existing_zip_id}" ]]; then
  api -X DELETE "https://api.github.com/repos/${REPO}/releases/assets/${existing_zip_id}" >/dev/null
fi
api -X POST "https://uploads.github.com/repos/${REPO}/releases/${release_id}/assets?name=${ZIP_NAME}" \
  --data-binary "@${ZIP_ASSET}" >/dev/null

echo "[5/5] Publish appcast.json to main"
git add dist/appcast.json
git commit -m "chore(release): appcast.json for ${TAG}" || true
git push origin main
```

(Adjust surrounding step-number echoes from `[N/3]` to `[N/5]` for consistency.)

- [ ] **Step 4: Commit**

```bash
git add dist/appcast.json scripts/publish_release.sh
git commit -m "feat(release): publish OTA zip asset + appcast.json"
```

---

## Task 12: README docs (en + zh)

**Files:**
- Modify: `README.md`
- Modify: `README.zh.md`

- [ ] **Step 1: Add an "Automatic updates" subsection to `README.md`** (in the Features or Permissions area):

```markdown
### Automatic updates

Plumb checks for updates on launch (once per ~6 hours) and via **Settings → Check for Updates…** (menu bar). When a newer version is available, you can update with one click — Plumb downloads the update, verifies its checksum, and replaces itself. Your Accessibility / Screen Recording permissions are preserved across updates (see [Why permissions may need re-granting](#why-permissions-may-need-re-granting-and-how-this-is-fixed)).
```

- [ ] **Step 2: Add the Chinese mirror to `README.zh.md`** (in the 权限说明 area):

```markdown
### 自动更新

Plumb 会在启动时（每 6 小时一次）以及通过菜单栏的「检查更新…」检查更新。检测到新版本时可一键更新——Plumb 会下载更新包、校验完整性并替换自身。更新后你的辅助功能 / 屏幕录制权限会被保留（见[为什么权限可能需要重新授权](#为什么权限可能需要重新授权以及如何修复)）。
```

- [ ] **Step 3: Commit**

```bash
git add README.md README.zh.md
git commit -m "docs(readme): document in-app automatic updates"
```

---

## Done Criteria (spec §9)

- [ ] Tasks 1–4: pure-logic unit tests green (AppVersion, UpdateManifest, UpdateChecker, UpdateDownloader).
- [ ] Task 5–6: UpdateCoordinator + UpdateInstaller compile and wire correctly.
- [ ] Task 7: OTA keys in all 5 language tables (Localization completeness test green).
- [ ] Task 8: menu item + background check + installer-mode branch wired; full test suite green.
- [ ] Task 9 (manual): end-to-end update works; version changes; permissions persist (with stable signing cert).
- [ ] Task 10–11: create_zip.sh produces a signed zip; publish_release.sh uploads zip + appcast.
- [ ] Task 12: README en/zh document automatic updates.
- [ ] `swift test` green; `swift build -c release` succeeds.

## Notes for executor

- **Task ordering:** Do Tasks 1, 2, 3, 4 (TDD), then Task 7 (Localization — needed by Tasks 5 & 6 to compile), then Tasks 5 & 6, then Task 8, then manual Task 9, then packaging Tasks 10–11, then docs Task 12.
- **Stable signing dependency:** Task 9 Step 6 (permission persistence) requires the signing-fix cert to be trusted. If that's not done yet, Task 9 Steps 1–5 still validate the OTA flow; Step 6 is deferred until the cert is trusted.
- **No placeholders:** the `AuthorizationExecuteWithPrivileges` path in Task 6 may need the AppleScript fallback if it fails to build — that's a documented contingency, not a placeholder.
