import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateManifest
//
// 模块角色：appcast.json 的数据模型（Codable）。
//
// 职责：
//   - 解码 appcast 的 version/url/sha256/notes/minOS 五个字段。
//   - notes(for:)：按当前 UI 语言取文案，缺失回退英语。
//   - parsedVersion / minOS：把字符串版本转成 AppVersion，非法时 nil。
// ─────────────────────────────────────────────────────────────────────────────

/// appcast.json 模型。单条记录指向"最新版本"。
struct UpdateManifest: Codable {
    let version: String
    let url: URL
    let sha256: String
    let notes: [String: String]
    /// 最低系统版本要求；缺失时为 nil（视为无门槛）。
    let minOS: AppVersion?

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
        let code = Self.languageCode(for: language)
        if let v = notes[code] { return v }
        return notes["en"] ?? ""
    }

    private static func languageCode(for language: AppLanguage) -> String {
        switch language {
        case .zh: return "zh"
        case .en: return "en"
        case .es: return "es"
        case .fr: return "fr"
        case .ja: return "ja"
        }
    }
}
