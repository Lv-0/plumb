import Foundation
import Testing
@testable import Plumb

@Test("launch-only centering permits launch activations and preserves tiling")
func launchOnlyCenteringTriggerPolicy() {
    var settings = AppTilingSettings.default
    settings.centerOnlyOnAppLaunch = true

    #expect(AutomaticCenteringTriggerPolicy.resolvedLayoutMode(
        settings: settings,
        bundleIdentifier: "com.example.centered",
        isLaunchAuthorizedActivation: true
    ) == .center)
    #expect(AutomaticCenteringTriggerPolicy.resolvedLayoutMode(
        settings: settings,
        bundleIdentifier: "com.example.centered",
        isLaunchAuthorizedActivation: false
    ) == .none)

    settings.isEnabled = true
    settings.tiledBundleIDs = ["com.example.tiled"]
    #expect(AutomaticCenteringTriggerPolicy.resolvedLayoutMode(
        settings: settings,
        bundleIdentifier: "com.example.tiled",
        isLaunchAuthorizedActivation: false
    ) == .tile)

    settings.centerOnlyOnAppLaunch = false
    #expect(AutomaticCenteringTriggerPolicy.resolvedLayoutMode(
        settings: settings,
        bundleIdentifier: "com.example.centered",
        isLaunchAuthorizedActivation: false
    ) == .center)
}

@Test("launch admission is exact, single-use, and expires")
func applicationLaunchAdmissionTrackerSemantics() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let launchDate = Date(timeIntervalSinceReferenceDate: 900)
    let original = ProcessIncarnation(startSeconds: 100, startMicroseconds: 1)
    let replacement = ProcessIncarnation(startSeconds: 101, startMicroseconds: 1)
    var tracker = ApplicationLaunchAdmissionTracker()

    tracker.record(pid: 42, incarnation: original, launchDate: launchDate, now: now)
    let mismatched = tracker.consume(pid: 42, incarnation: replacement, launchDate: launchDate, now: now)
    #expect(!mismatched)

    tracker.record(pid: 42, incarnation: original, launchDate: launchDate, now: now)
    let matched = tracker.consume(pid: 42, incarnation: original, launchDate: launchDate, now: now)
    let consumedAgain = tracker.consume(pid: 42, incarnation: original, launchDate: launchDate, now: now)
    #expect(matched)
    #expect(!consumedAgain)

    tracker.record(pid: 43, incarnation: original, launchDate: launchDate, now: now, validityInterval: 1)
    let expired = tracker.consume(
        pid: 43,
        incarnation: original,
        launchDate: launchDate,
        now: now.addingTimeInterval(2)
    )
    #expect(!expired)

    tracker.record(pid: 44, incarnation: nil, launchDate: launchDate, now: now)
    let matchedByLaunchDate = tracker.consume(pid: 44, incarnation: nil, launchDate: launchDate, now: now)
    #expect(matchedByLaunchDate)

    tracker.record(pid: 45, incarnation: replacement, launchDate: launchDate, now: now)
    let staleTerminationRemoved = tracker.removeIfMatching(
        pid: 45,
        incarnation: nil,
        launchDate: launchDate.addingTimeInterval(-100)
    )
    let survivedStaleTermination = tracker.consume(
        pid: 45,
        incarnation: replacement,
        launchDate: launchDate,
        now: now
    )
    #expect(!staleTerminationRemoved)
    #expect(survivedStaleTermination)

    tracker.record(pid: 46, incarnation: original, launchDate: launchDate, now: now)
    let matchingTerminationRemoved = tracker.removeIfMatching(
        pid: 46,
        incarnation: original,
        launchDate: launchDate
    )
    let removedAdmissionCannotBeConsumed = tracker.consume(
        pid: 46,
        incarnation: original,
        launchDate: launchDate,
        now: now
    )
    #expect(matchingTerminationRemoved)
    #expect(!removedAdmissionCannotBeConsumed)
}

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

@Test("multiple document windows own independent classification gates")
func multipleDocumentClassificationGateOwnersRemainIndependent() {
    let token = LayoutActivationToken(pid: 42, generation: 1)
    let first = LayoutContinuationLease(token: token, sequence: 11, operationID: nil, windowKey: "42:first")
    let second = LayoutContinuationLease(token: token, sequence: 12, operationID: nil, windowKey: "42:second")
    var state = MultiOwnedOperationState<String, LayoutContinuationLease>()

    _ = state.begin(owner: first, for: "42:first")
    _ = state.begin(owner: second, for: "42:second")

    #expect(state.owns(first, for: "42:first"))
    #expect(state.owns(second, for: "42:second"))
    let staleEnd = state.end(ifOwnedBy: first, for: "42:second")
    #expect(!staleEnd)
    let firstEnd = state.end(ifOwnedBy: first, for: "42:first")
    #expect(firstEnd)
    #expect(state.owns(second, for: "42:second"))
}

@Test("only a new eligible no-pointer document identity begins startup bootstrap")
func documentStartupBootstrapAdmissionIsNarrow() {
    #expect(DocumentStartupNotificationPolicy.disposition(
        isKnownWindow: false,
        hasActiveBootstrap: false,
        canBeginBootstrap: true,
        pointerButtonDown: false
    ) == .beginBootstrap)
    #expect(DocumentStartupNotificationPolicy.disposition(
        isKnownWindow: true,
        hasActiveBootstrap: false,
        canBeginBootstrap: true,
        pointerButtonDown: false
    ) == .markManual)
    #expect(DocumentStartupNotificationPolicy.disposition(
        isKnownWindow: false,
        hasActiveBootstrap: false,
        canBeginBootstrap: false,
        pointerButtonDown: false
    ) == .markManual)
}

@Test("startup bootstrap suppresses app geometry but pointer evidence stays manual")
func documentStartupBootstrapPreservesUserIntent() {
    #expect(DocumentStartupNotificationPolicy.disposition(
        isKnownWindow: true,
        hasActiveBootstrap: true,
        canBeginBootstrap: true,
        pointerButtonDown: false
    ) == .suppressDuringBootstrap)
    #expect(DocumentStartupNotificationPolicy.disposition(
        isKnownWindow: true,
        hasActiveBootstrap: true,
        canBeginBootstrap: true,
        pointerButtonDown: true
    ) == .markManual)
    #expect(DocumentStartupNotificationPolicy.disposition(
        isKnownWindow: false,
        hasActiveBootstrap: false,
        canBeginBootstrap: true,
        pointerButtonDown: true
    ) == .markManual)
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
