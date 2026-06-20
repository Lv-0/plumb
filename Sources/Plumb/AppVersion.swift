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
struct AppVersion: Comparable, Equatable, Codable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "major.minor.patch" 字符串形式，用于 UI 展示（如设置「关于」标签页的版本号）。
    var formatted: String { "\(major).\(minor).\(patch)" }

    /// 从字符串解析；支持可选前导 'v'，接受 2 段（major.minor，patch=0）或 3 段。
    /// 非数字段或含非数字字符则返回 nil。
    init?(parsing raw: String) {
        var s = raw
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let maj = Int(parts[0]),
              let min = Int(parts[1]) else { return nil }
        let pat: Int
        if parts.count == 3 {
            guard let p = Int(parts[2]) else { return nil }
            pat = p
        } else {
            pat = 0
        }
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
