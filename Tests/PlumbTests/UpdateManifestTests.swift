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

    @Test("minOS defaults to nil when absent")
    func minOSDefaultsToNil() throws {
        let json = #"{"version":"1.0.0","url":"https://x/y.zip","sha256":"a","notes":{"en":"x"}}"#
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
        #expect(manifest.minOS == nil)
    }
}
