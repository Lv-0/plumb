/// Runtime wrapper around the pure single-flight state machine.
///
/// The coordinator owns pending payloads and promotes them in FIFO order. It
/// deliberately performs no AX work itself: `WindowEventObserver` remains the
/// main-actor effect owner, while this type makes operation ownership explicit
/// and independently testable.
final class LayoutSessionCoordinator<Payload> {
    struct Entry {
        let id: LayoutOperationID
        let payload: Payload
    }

    enum SubmissionResult {
        case startNow(Entry)
        case queued
        case duplicate
    }

    enum CompletionResult {
        case ignored
        case completed(next: Entry?)
    }

    private var state = LayoutSingleFlightState()
    private var payloads: [LayoutOperationID: Payload] = [:]

    var activeID: LayoutOperationID? { state.active }
    var queuedIDs: [LayoutOperationID] { state.queued }

    @discardableResult
    func submit(id: LayoutOperationID, payload: Payload) -> SubmissionResult {
        switch state.submit(id) {
        case .started:
            payloads[id] = payload
            return .startNow(Entry(id: id, payload: payload))
        case .queued:
            payloads[id] = payload
            return .queued
        case .duplicate:
            return .duplicate
        }
    }

    @discardableResult
    func complete(_ id: LayoutOperationID) -> CompletionResult {
        switch state.complete(id) {
        case .ignored:
            return .ignored
        case .completed(let nextID):
            payloads.removeValue(forKey: id)
            guard let nextID else { return .completed(next: nil) }
            guard let nextPayload = payloads[nextID] else {
                // Payload and state are one ownership unit. If that invariant is
                // broken, cancel rather than leaving a promoted operation that
                // can never execute.
                state.cancelAll()
                payloads.removeAll(keepingCapacity: false)
                return .completed(next: nil)
            }
            return .completed(next: Entry(id: nextID, payload: nextPayload))
        }
    }

    func cancelAll() {
        state.cancelAll()
        payloads.removeAll(keepingCapacity: false)
    }
}
