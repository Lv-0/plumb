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

@Test("animation notification policy defers ambiguous owner events to readback evidence")
func animationNotificationPolicyIsWindowScoped() {
    #expect(AnimationNotificationPolicy.disposition(
        isExactAnimationOwner: false,
        pointerButtonDown: false,
        ownerHasActiveDriftMonitor: true
    ) == .markManual)
    #expect(AnimationNotificationPolicy.disposition(
        isExactAnimationOwner: true,
        pointerButtonDown: false,
        ownerHasActiveDriftMonitor: true
    ) == .deferToOwnerDriftMonitor)
    #expect(AnimationNotificationPolicy.disposition(
        isExactAnimationOwner: true,
        pointerButtonDown: false,
        ownerHasActiveDriftMonitor: false
    ) == .markManual)
    #expect(AnimationNotificationPolicy.disposition(
        isExactAnimationOwner: true,
        pointerButtonDown: true,
        ownerHasActiveDriftMonitor: true
    ) == .interruptOwnerAndMarkManual)
}

@Test("background Space pass never degrades tiling to centering")
func backgroundSpaceLayoutPolicyPreservesResolvedMode() {
    #expect(BackgroundSpaceLayoutPolicy.disposition(for: .center) == .center)
    #expect(BackgroundSpaceLayoutPolicy.disposition(for: .tile) == .skipTiled)
    #expect(BackgroundSpaceLayoutPolicy.disposition(for: .none) == .skipDisabled)
}

@Test("stopped observer rejects a queued Accessibility grant hop")
func observerLifecycleRejectsGrantAfterStop() {
    var state = ObserverLifecycleState()
    let token = state.start()

    let beganPolling = state.beginAccessibilityPoll(ownedBy: token)
    #expect(beganPolling)
    state.stop()

    let consumedAfterStop = state.consumeAccessibilityGrant(ownedBy: token)
    #expect(!consumedAfterStop)
    #expect(state.activeToken == nil)
    #expect(state.accessibilityPollOwner == nil)
}

@Test("stale Accessibility grant cannot consume a replacement observer poll")
func observerLifecycleKeepsReplacementPollOwned() {
    var state = ObserverLifecycleState()
    let staleToken = state.start()
    let beganStalePolling = state.beginAccessibilityPoll(ownedBy: staleToken)
    #expect(beganStalePolling)
    state.stop()

    let currentToken = state.start()
    let beganCurrentPolling = state.beginAccessibilityPoll(ownedBy: currentToken)
    #expect(beganCurrentPolling)

    let staleConsumed = state.consumeAccessibilityGrant(ownedBy: staleToken)
    #expect(!staleConsumed)
    #expect(state.accessibilityPollOwner == currentToken)
    let currentConsumed = state.consumeAccessibilityGrant(ownedBy: currentToken)
    #expect(currentConsumed)
    #expect(state.accessibilityPollOwner == nil)
}

@Test("secondary and failed background records do not consume their PID")
func backgroundCandidateConsumptionWaitsForMainWindow() {
    #expect(!BackgroundWindowPIDConsumptionPolicy.shouldConsumePID(after: .unboundOrIneligibleRecord))
    #expect(!BackgroundWindowPIDConsumptionPolicy.shouldConsumePID(after: .secondaryWindow))
    #expect(!BackgroundWindowPIDConsumptionPolicy.shouldConsumePID(after: .excludedSpecialWindow))
    #expect(BackgroundWindowPIDConsumptionPolicy.shouldConsumePID(after: .alreadyHandledMainWindow))
    #expect(BackgroundWindowPIDConsumptionPolicy.shouldConsumePID(after: .centerStarted))
    #expect(BackgroundWindowPIDConsumptionPolicy.shouldConsumePID(after: .centerCompletedSynchronously))
}

@Test("every background writer terminal advances the pass")
func backgroundTerminalOutcomesAlwaysContinue() {
    let finished = BackgroundCenterTerminalPolicy.decision(
        outcome: .finished,
        centeredReadbackMatches: true
    )
    let missedReadback = BackgroundCenterTerminalPolicy.decision(
        outcome: .finished,
        centeredReadbackMatches: false
    )
    let failed = BackgroundCenterTerminalPolicy.decision(
        outcome: .writerFailed,
        centeredReadbackMatches: false
    )
    let interrupted = BackgroundCenterTerminalPolicy.decision(
        outcome: .userInterrupted,
        centeredReadbackMatches: false
    )

    #expect(finished == BackgroundCenterTerminalDecision(
        markManual: false,
        markCentered: true,
        continueScan: true
    ))
    #expect(!missedReadback.markCentered)
    #expect(missedReadback.continueScan)
    #expect(!failed.markCentered)
    #expect(failed.continueScan)
    #expect(interrupted.markManual)
    #expect(interrupted.continueScan)
}

@Test("background busy retry is delayed and bounded")
func backgroundBusyRetryDoesNotSpinForever() {
    #expect(BackgroundCenterBusyRetryPolicy.decision(afterAttemptCount: 1) == .retry(after: 0.10))
    #expect(BackgroundCenterBusyRetryPolicy.decision(
        afterAttemptCount: BackgroundCenterBusyRetryPolicy.maxAttempts - 1
    ) == .retry(after: 0.10))
    #expect(BackgroundCenterBusyRetryPolicy.decision(
        afterAttemptCount: BackgroundCenterBusyRetryPolicy.maxAttempts
    ) == .abandonCurrentPID)
}
