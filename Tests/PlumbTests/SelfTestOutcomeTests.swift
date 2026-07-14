import Testing
@testable import Plumb

@Suite(.serialized)
@MainActor
struct SelfTestOutcomeTests {
    @Test
    func cleanRunExitsSuccessfully() {
        SelfTestOutcome.reset()
        SelfTestOutcome.observe("SELFTEST: RESULT=PASS")

        #expect(SelfTestOutcome.failureMessages.isEmpty)
        #expect(SelfTestOutcome.exitCode == 0)
    }

    @Test
    func failAndCheckMessagesExitNonzero() {
        SelfTestOutcome.reset()
        SelfTestOutcome.observe("SELFTEST: RESULT=CHECK")
        SelfTestOutcome.observe("SELFTEST: FAIL — target missing")

        #expect(SelfTestOutcome.failureMessages.count == 2)
        #expect(SelfTestOutcome.exitCode == 1)
    }

    @Test
    func explicitFailureExitsNonzero() {
        SelfTestOutcome.reset()
        SelfTestOutcome.recordFailure("missing prerequisite")

        #expect(SelfTestOutcome.failureMessages == ["missing prerequisite"])
        #expect(SelfTestOutcome.exitCode == 1)
    }
}
