import Testing
@testable import Plumb

@Test("coordinator retains payloads and promotes them in FIFO order")
func coordinatorPromotesPayloadsInFIFOOrder() {
    let token = LayoutActivationToken(pid: 42, generation: 7)
    let first = LayoutOperationID(token: token, windowKey: "a", kind: .tile)
    let second = LayoutOperationID(token: token, windowKey: "b", kind: .tile)
    let third = LayoutOperationID(token: token, windowKey: "c", kind: .tile)
    let coordinator = LayoutSessionCoordinator<String>()

    switch coordinator.submit(id: first, payload: "first") {
    case .startNow(let entry):
        #expect(entry.id == first)
        #expect(entry.payload == "first")
    default:
        Issue.record("first operation should start immediately")
    }
    if case .queued = coordinator.submit(id: second, payload: "second") {} else {
        Issue.record("second operation should queue")
    }
    if case .queued = coordinator.submit(id: third, payload: "third") {} else {
        Issue.record("third operation should queue")
    }

    switch coordinator.complete(first) {
    case .completed(let next):
        #expect(next?.id == second)
        #expect(next?.payload == "second")
    case .ignored:
        Issue.record("active completion should be accepted")
    }
    switch coordinator.complete(second) {
    case .completed(let next):
        #expect(next?.id == third)
        #expect(next?.payload == "third")
    case .ignored:
        Issue.record("second completion should be accepted")
    }
}

@Test("stale completion cannot promote or discard current work")
func coordinatorIgnoresStaleCompletion() {
    let token = LayoutActivationToken(pid: 42, generation: 7)
    let active = LayoutOperationID(token: token, windowKey: "a", kind: .tile)
    let queued = LayoutOperationID(token: token, windowKey: "b", kind: .tile)
    let stale = LayoutOperationID(
        token: LayoutActivationToken(pid: 42, generation: 6),
        windowKey: "a",
        kind: .tile
    )
    let coordinator = LayoutSessionCoordinator<Int>()

    _ = coordinator.submit(id: active, payload: 1)
    _ = coordinator.submit(id: queued, payload: 2)

    if case .ignored = coordinator.complete(stale) {} else {
        Issue.record("stale completion must be ignored")
    }
    #expect(coordinator.activeID == active)
    #expect(coordinator.queuedIDs == [queued])
}

@Test("cancelling a coordinator drops active and queued payloads")
func coordinatorCancellationDropsAllWork() {
    let token = LayoutActivationToken(pid: 42, generation: 7)
    let first = LayoutOperationID(token: token, windowKey: "a", kind: .tile)
    let second = LayoutOperationID(token: token, windowKey: "b", kind: .tile)
    let coordinator = LayoutSessionCoordinator<String>()

    _ = coordinator.submit(id: first, payload: "first")
    _ = coordinator.submit(id: second, payload: "second")
    coordinator.cancelAll()

    #expect(coordinator.activeID == nil)
    #expect(coordinator.queuedIDs.isEmpty)
    if case .ignored = coordinator.complete(first) {} else {
        Issue.record("cancelled operation completion must be ignored")
    }
}
