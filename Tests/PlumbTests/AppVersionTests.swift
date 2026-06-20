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
        #expect(AppVersion(major: 1, minor: 0, patch: 6).isNewerThan(current))
        #expect(!AppVersion(major: 1, minor: 0, patch: 5).isNewerThan(current))   // equal → not newer
        #expect(!AppVersion(major: 1, minor: 0, patch: 4).isNewerThan(current))   // older → not newer
    }
}
