import Testing
@testable import Plumb

@Suite("Localization")
struct LocalizationTests {

    // MARK: - AppLanguage.resolve(from:)

    @Test("zh variants resolve to .zh")
    func zhVariants() {
        #expect(AppLanguage.resolve(from: ["zh-Hans-CN"]) == .zh)
        #expect(AppLanguage.resolve(from: ["zh-Hant-TW"]) == .zh)
        #expect(AppLanguage.resolve(from: ["zh"]) == .zh)
    }

    @Test("en variants resolve to .en")
    func enVariants() {
        #expect(AppLanguage.resolve(from: ["en-US"]) == .en)
        #expect(AppLanguage.resolve(from: ["en-GB"]) == .en)
        #expect(AppLanguage.resolve(from: ["en"]) == .en)
    }

    @Test("ja variants resolve to .ja")
    func jaVariants() {
        #expect(AppLanguage.resolve(from: ["ja-JP"]) == .ja)
        #expect(AppLanguage.resolve(from: ["ja"]) == .ja)
    }

    @Test("unsupported first preference falls through to a later supported one")
    func fallbackWithinList() {
        #expect(AppLanguage.resolve(from: ["fr-FR", "en-US"]) == .en)
        #expect(AppLanguage.resolve(from: ["de-DE", "ja-JP"]) == .ja)
    }

    @Test("no supported language in list falls back to .en")
    func noMatchFallsBackToEnglish() {
        #expect(AppLanguage.resolve(from: ["fr-FR"]) == .en)
        #expect(AppLanguage.resolve(from: ["ko-KR", "fr-FR"]) == .en)
    }

    @Test("first user preference wins when multiple supported present")
    func firstPreferenceWins() {
        #expect(AppLanguage.resolve(from: ["ja", "zh"]) == .ja)
        #expect(AppLanguage.resolve(from: ["zh", "en"]) == .zh)
    }

    @Test("empty preference list falls back to .en")
    func emptyListFallback() {
        #expect(AppLanguage.resolve(from: []) == .en)
    }

    // MARK: - Table completeness

    @Test("every key is present and non-empty in every supported language")
    func tableCompleteness() throws {
        for lang in [AppLanguage.zh, .en, .ja] {
            let dict = try #require(L10n.table[lang])
            for key in L10n.Key.allCases {
                let v = try #require(dict[key], "Missing key \(key.rawValue) in \(lang)")
                #expect(!v.isEmpty, "Empty value for key \(key.rawValue) in \(lang)")
            }
        }
    }

    // MARK: - Accessor smoke (renders without crashing, returns localized value)

    @Test("toggleState mirrors on/off")
    func toggleStateMirror() {
        #expect(L10n.toggleState(true) == L10n.on)
        #expect(L10n.toggleState(false) == L10n.off)
    }

    @Test("appName is the unlocalized brand constant")
    func appNameUnlocalized() {
        #expect(L10n.appName == "Plumb")
    }
}
