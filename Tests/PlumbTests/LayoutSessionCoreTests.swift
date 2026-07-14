import Testing
@testable import Plumb

@Test("process identity rejects a recycled PID")
func processIdentityRejectsRecycledPID() {
    let old = ProcessIncarnation(startSeconds: 100, startMicroseconds: 1)
    let replacement = ProcessIncarnation(startSeconds: 101, startMicroseconds: 2)

    #expect(!ProcessIdentityPolicy.isSameProcess(
        pidMatches: true,
        observedIncarnation: old,
        currentIncarnation: replacement,
        fallbackLaunchDatesMatch: true
    ))
}

@Test("process identity accepts the same kernel incarnation")
func processIdentityAcceptsSameKernelIncarnation() {
    let incarnation = ProcessIncarnation(startSeconds: 100, startMicroseconds: 1)

    #expect(ProcessIdentityPolicy.isSameProcess(
        pidMatches: true,
        observedIncarnation: incarnation,
        currentIncarnation: incarnation,
        fallbackLaunchDatesMatch: false
    ))
}

@Test("process identity uses launch date only when kernel identity is unavailable")
func processIdentityUsesConservativeFallback() {
    #expect(ProcessIdentityPolicy.isSameProcess(
        pidMatches: true,
        observedIncarnation: nil,
        currentIncarnation: nil,
        fallbackLaunchDatesMatch: true
    ))
    #expect(!ProcessIdentityPolicy.isSameProcess(
        pidMatches: true,
        observedIncarnation: nil,
        currentIncarnation: nil,
        fallbackLaunchDatesMatch: nil
    ))
    #expect(!ProcessIdentityPolicy.isSameProcess(
        pidMatches: false,
        observedIncarnation: nil,
        currentIncarnation: nil,
        fallbackLaunchDatesMatch: true
    ))
}

@Test("a new activation makes the previous token stale")
func newActivationMakesPreviousTokenStale() {
    var tracker = LayoutActivationTracker()

    let first = tracker.activate(pid: 100)
    let second = tracker.activate(pid: 200)

    #expect(first.generation != second.generation)
    #expect(!tracker.isCurrent(first))
    #expect(tracker.isCurrent(second))
}

@Test("PID reuse cannot revive an invalidated activation token")
func pidReuseCannotReviveInvalidatedToken() {
    var tracker = LayoutActivationTracker()

    let original = tracker.activate(pid: 100)
    tracker.invalidate()
    let reusedPID = tracker.activate(pid: 100)

    #expect(original.pid == reusedPID.pid)
    #expect(original.generation != reusedPID.generation)
    #expect(!tracker.isCurrent(original))
    #expect(tracker.isCurrent(reusedPID))
}

@Test("stale invalidation cannot clear a newer activation")
func staleInvalidationCannotClearNewerActivation() {
    var tracker = LayoutActivationTracker()

    let stale = tracker.activate(pid: 100)
    let current = tracker.activate(pid: 100)

    let staleInvalidationSucceeded = tracker.invalidate(stale)
    #expect(!staleInvalidationSucceeded)
    #expect(tracker.isCurrent(current))
    let currentInvalidationSucceeded = tracker.invalidate(current)
    #expect(currentInvalidationSucceeded)
    #expect(tracker.currentToken == nil)
}

@Test("wrong completion does not clear or advance the active operation")
func wrongCompletionDoesNotAdvanceSingleFlight() {
    let token = LayoutActivationToken(pid: 100, generation: 1)
    let active = operation(token: token, window: "100:1", kind: .tile)
    let queued = operation(token: token, window: "100:2", kind: .center)
    let wrong = operation(token: token, window: "100:3", kind: .tile)
    var state = LayoutSingleFlightState()

    #expect(state.submit(active) == .started)
    #expect(state.submit(queued) == .queued)
    #expect(state.complete(wrong) == .ignored)
    #expect(state.active == active)
    #expect(state.queued == [queued])
}

@Test("valid completions promote queued operations in FIFO order")
func validCompletionsPromoteOperationsInFIFOOrder() {
    let token = LayoutActivationToken(pid: 100, generation: 1)
    let first = operation(token: token, window: "100:1", kind: .tile)
    let second = operation(token: token, window: "100:2", kind: .center)
    let third = operation(token: token, window: "100:3", kind: .tile)
    var state = LayoutSingleFlightState()

    #expect(state.submit(first) == .started)
    #expect(state.submit(second) == .queued)
    #expect(state.submit(third) == .queued)
    #expect(state.queued == [second, third])

    #expect(state.complete(first) == .completed(next: second))
    #expect(state.active == second)
    #expect(state.queued == [third])
    #expect(state.complete(second) == .completed(next: third))
    #expect(state.active == third)
    #expect(state.queued.isEmpty)
    #expect(state.complete(third) == .completed(next: nil))
    #expect(state.active == nil)
}

@Test("an operation is never duplicated while active or queued")
func operationIsNeverDuplicated() {
    let token = LayoutActivationToken(pid: 100, generation: 1)
    let active = operation(token: token, window: "100:1", kind: .tile)
    let queued = operation(token: token, window: "100:2", kind: .center)
    var state = LayoutSingleFlightState()

    #expect(state.submit(active) == .started)
    #expect(state.submit(active) == .duplicate)
    #expect(state.submit(queued) == .queued)
    #expect(state.submit(queued) == .duplicate)
    #expect(state.active == active)
    #expect(state.queued == [queued])
}

@Test("cancel all clears active and queued operations")
func cancelAllClearsSingleFlightState() {
    let token = LayoutActivationToken(pid: 100, generation: 1)
    let active = operation(token: token, window: "100:1", kind: .tile)
    let queued = operation(token: token, window: "100:2", kind: .center)
    var state = LayoutSingleFlightState()

    #expect(state.submit(active) == .started)
    #expect(state.submit(queued) == .queued)
    state.cancelAll()

    #expect(state.active == nil)
    #expect(state.queued.isEmpty)
}

@Test("an old continuation lease cannot clear its replacement")
func oldContinuationLeaseCannotClearReplacement() {
    let token = LayoutActivationToken(pid: 100, generation: 1)
    let old = LayoutContinuationLease(token: token, sequence: 1, operationID: nil, windowKey: nil)
    let replacement = LayoutContinuationLease(token: token, sequence: 2, operationID: nil, windowKey: nil)
    var ownership = OwnedOperationState<LayoutContinuationLease>()

    _ = ownership.begin(owner: old)
    _ = ownership.begin(owner: replacement)

    let staleEnded = ownership.end(ifOwnedBy: old)
    #expect(!staleEnded)
    #expect(ownership.owner == replacement)
    let replacementEnded = ownership.end(ifOwnedBy: replacement)
    #expect(replacementEnded)
    #expect(ownership.owner == nil)
}

@Test("operation sequence prevents same-window ABA completion")
func operationSequencePreventsABACompletion() {
    let token = LayoutActivationToken(pid: 100, generation: 1)
    let old = LayoutOperationID(token: token, windowKey: "window", kind: .tile, sequence: 1)
    let replacement = LayoutOperationID(token: token, windowKey: "window", kind: .tile, sequence: 2)
    var state = LayoutSingleFlightState()

    #expect(state.submit(replacement) == .started)
    #expect(state.complete(old) == .ignored)
    #expect(state.active == replacement)
}

private func operation(
    token: LayoutActivationToken,
    window: String,
    kind: LayoutOperationKind
) -> LayoutOperationID {
    LayoutOperationID(token: token, windowKey: window, kind: kind)
}
