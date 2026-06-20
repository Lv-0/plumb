import Testing
import Foundation
@testable import Plumb

@Suite("UpdateChecker")
struct UpdateCheckerTests {

    /// 固定返回给定 Data 的 fetcher，用于注入（测试不触网）。
    private struct MockFetcher: ManifestFetcher {
        let data: Data?
        let error: Error?
        init(data: Data?, error: Error? = nil) {
            self.data = data
            self.error = error
        }
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
    func upToDate() async {
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data(manifestJSON(version: "1.0.0").utf8)))
        let result = await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: AppVersion(major: 26, minor: 0, patch: 0))
        guard case .upToDate = result else { Issue.record("expected upToDate"); return }
    }

    @Test("returns available when manifest version is newer")
    func available() async {
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data(manifestJSON(version: "1.0.6").utf8)))
        let result = await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: AppVersion(major: 26, minor: 0, patch: 0))
        guard case .available(let m) = result else { Issue.record("expected available"); return }
        #expect(m.version == "1.0.6")
    }

    @Test("treats older manifest version as upToDate (only-up)")
    func onlyUp() async {
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data(manifestJSON(version: "0.9.0").utf8)))
        let result = await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: AppVersion(major: 26, minor: 0, patch: 0))
        guard case .upToDate = result else { Issue.record("older version should be upToDate"); return }
    }

    @Test("treats malformed manifest version as upToDate")
    func malformedVersion() async {
        let json = #"{"version":"latest","url":"https://x/y.zip","sha256":"a","notes":{"en":"n"},"minOS":"0.0.0"}"#
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data(json.utf8)))
        let result = await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: AppVersion(major: 26, minor: 0, patch: 0))
        guard case .upToDate = result else { Issue.record("malformed should be upToDate"); return }
    }

    @Test("returns osTooOld when minOS exceeds running OS")
    func osTooOld() async {
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data(manifestJSON(version: "2.0.0", minOS: "27.0").utf8)))
        let result = await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: AppVersion(major: 26, minor: 0, patch: 0))
        guard case .osTooOld = result else { Issue.record("expected osTooOld"); return }
    }

    @Test("returns error when fetcher throws")
    func fetchError() async {
        let checker = UpdateChecker(fetcher: MockFetcher(data: nil, error: StubError()))
        let result = await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: AppVersion(major: 26, minor: 0, patch: 0))
        guard case .error = result else { Issue.record("expected error"); return }
    }

    @Test("returns error when manifest JSON is unparseable")
    func unparseableJSON() async {
        let checker = UpdateChecker(fetcher: MockFetcher(data: Data("not json".utf8)))
        let result = await checker.check(current: AppVersion(major: 1, minor: 0, patch: 0), osVersion: AppVersion(major: 26, minor: 0, patch: 0))
        guard case .error = result else { Issue.record("expected error"); return }
    }
}
