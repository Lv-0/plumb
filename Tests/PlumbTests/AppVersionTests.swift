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

    @Test("accepts 2- and 3-segment forms, rejects malformed")
    func parsingForms() {
        #expect(AppVersion(parsing: "1.0") == AppVersion(major: 1, minor: 0, patch: 0))   // 2-seg → patch 0
        #expect(AppVersion(parsing: "26.1") == AppVersion(major: 26, minor: 1, patch: 0))
        #expect(AppVersion(parsing: "1.x.3") == nil)
        #expect(AppVersion(parsing: "") == nil)
        #expect(AppVersion(parsing: "latest") == nil)
        #expect(AppVersion(parsing: "1") == nil)                                            // 1-seg rejected
        #expect(AppVersion(parsing: "1.2.3.4") == nil)                                      // 4-seg rejected
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
        #expect(AppVersion(major: 1, minor: 0, patch: 6).isNewerThan(current))
        #expect(!AppVersion(major: 1, minor: 0, patch: 5).isNewerThan(current))   // equal → not newer
        #expect(!AppVersion(major: 1, minor: 0, patch: 4).isNewerThan(current))   // older → not newer
    }

    // MARK: - formatted (UI display)

    @Test("formatted renders as major.minor.patch string")
    func formattedRendersTriple() {
        #expect(AppVersion(major: 1, minor: 0, patch: 6).formatted == "1.0.6")
        #expect(AppVersion(major: 2, minor: 13, patch: 0).formatted == "2.13.0")
        #expect(AppVersion(major: 0, minor: 0, patch: 0).formatted == "0.0.0")
    }
}
