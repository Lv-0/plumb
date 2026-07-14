import Testing
@testable import Plumb

@Test("owned operation ignores cleanup from an unrelated owner")
func ownedOperationIgnoresUnrelatedOwnerCleanup() {
    var state = OwnedOperationState<Int>()

    #expect(state.begin(owner: 100) == nil)
    #expect(state.owner == 100)
    #expect(state.end(ifOwnedBy: 200) == false)
    #expect(state.owner == 100)
    #expect(state.end(ifOwnedBy: 100) == true)
    #expect(state.owner == nil)
}

@Test("owned operation replacement reports the previous owner")
func ownedOperationReplacementReportsPreviousOwner() {
    var state = OwnedOperationState<Int>()

    #expect(state.begin(owner: 100) == nil)
    #expect(state.begin(owner: 101) == 100)
    #expect(state.owner == 101)
    state.reset()
    #expect(state.owner == nil)
}

@Test("only retry outcome keeps initial polling alive")
func onlyRetryOutcomeContinuesInitialPolling() {
    #expect(HandleOutcome.retry.shouldContinueInitialRetry)
    #expect(!HandleOutcome.completed.shouldContinueInitialRetry)
    #expect(!HandleOutcome.ignored.shouldContinueInitialRetry)
}

@Test("tile attempt accounting terminates synchronous unsatisfied no-ops")
func tileAttemptAccountingHandlesSynchronousNoOp() {
    #expect(TileAttemptAccountingPolicy.shouldCount(
        startResult: .started,
        targetSatisfied: false
    ))
    #expect(TileAttemptAccountingPolicy.shouldCount(
        startResult: .completedSynchronously(didWriteGeometry: false),
        targetSatisfied: false
    ))
    #expect(!TileAttemptAccountingPolicy.shouldCount(
        startResult: .completedSynchronously(didWriteGeometry: false),
        targetSatisfied: true
    ))
    #expect(!TileAttemptAccountingPolicy.shouldCount(
        startResult: .busy,
        targetSatisfied: false
    ))
}

@Test("multiple document windows own independent stable gates")
func multipleDocumentStableGateOwnersRemainIndependent() {
    let token = LayoutActivationToken(pid: 42, generation: 1)
    let first = LayoutContinuationLease(token: token, sequence: 1, operationID: nil, windowKey: "42:first")
    let second = LayoutContinuationLease(token: token, sequence: 2, operationID: nil, windowKey: "42:second")
    var state = MultiOwnedOperationState<String, LayoutContinuationLease>()

    _ = state.begin(owner: first, for: "42:first")
    _ = state.begin(owner: second, for: "42:second")
    #expect(state.keys == ["42:first", "42:second"])

    let staleEnd = state.end(ifOwnedBy: first, for: "42:second")
    #expect(!staleEnd)
    #expect(state.owns(second, for: "42:second"))

    let firstEnd = state.end(ifOwnedBy: first, for: "42:first")
    #expect(firstEnd)
    #expect(!state.owns(first, for: "42:first"))
    #expect(state.owns(second, for: "42:second"))
}

@Test("termination policy preserves a running replacement even after it was attached")
func terminationPolicyPreservesRunningReplacement() {
    #expect(!TerminationNotificationPolicy.shouldIgnore(
        observedPIDMatches: true,
        launchDatesMismatch: false,
        terminatedAppReportsTerminated: true,
        liveAppIsRunning: false
    ))
    #expect(TerminationNotificationPolicy.shouldIgnore(
        observedPIDMatches: true,
        launchDatesMismatch: false,
        terminatedAppReportsTerminated: true,
        liveAppIsRunning: true
    ))
    #expect(!TerminationNotificationPolicy.shouldIgnore(
        observedPIDMatches: false,
        launchDatesMismatch: false,
        terminatedAppReportsTerminated: true,
        liveAppIsRunning: true
    ))
}

@Test("synchronous animation result distinguishes AX writes from no-ops")
func synchronousAnimationResultCarriesWriteSemantics() {
    #expect(WindowAnimationStartResult.completedSynchronously(didWriteGeometry: true).synchronousWriteOccurred)
    #expect(!WindowAnimationStartResult.completedSynchronously(didWriteGeometry: false).synchronousWriteOccurred)
    #expect(WindowAnimationStartResult.completedSynchronously(didWriteGeometry: false).isCompletedSynchronously)
    #expect(!WindowAnimationStartResult.started.isCompletedSynchronously)
}
