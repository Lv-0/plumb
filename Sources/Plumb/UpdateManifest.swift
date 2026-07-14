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
        let version = try c.decode(String.self, forKey: .version)
        guard AppVersion(parsing: version) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: c,
                debugDescription: "Invalid update version: \(version)"
            )
        }
        self.version = version

        let url = try c.decode(URL.self, forKey: .url)
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw DecodingError.dataCorruptedError(
                forKey: .url,
                in: c,
                debugDescription: "Update URL must be an absolute HTTPS URL"
            )
        }
        self.url = url

        let sha256 = try c.decode(String.self, forKey: .sha256)
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
              })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .sha256,
                in: c,
                debugDescription: "sha256 must contain exactly 64 hexadecimal characters"
            )
        }
        self.sha256 = sha256
        self.notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
        if let minOSRaw = try c.decodeIfPresent(String.self, forKey: .minOS) {
            // “缺失”与“存在但非法”必须分开：缺失保留旧 manifest 的无门槛语义；
            // 非法值则是发布数据错误，必须 fail closed。若将非法值 flatMap 成 nil，反而会
            // 取消系统版本门槛，向不兼容的 macOS 提供无法启动的更新。
            guard let parsed = AppVersion(parsing: minOSRaw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .minOS,
                    in: c,
                    debugDescription: "Invalid minOS version: \(minOSRaw)"
                )
            }
            self.minOS = parsed
        } else {
            self.minOS = nil
        }
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
