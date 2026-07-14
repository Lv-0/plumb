/// Kernel-backed identity for one process lifetime. A numeric PID may be reused;
/// the process start timestamp must change for the replacement lifetime.
struct ProcessIncarnation: Hashable, Sendable {
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

/// Pure fallback policy used before reusing an existing AX observer.
enum ProcessIdentityPolicy {
    static func isSameProcess(
        pidMatches: Bool,
        observedIncarnation: ProcessIncarnation?,
        currentIncarnation: ProcessIncarnation?,
        fallbackLaunchDatesMatch: Bool?
    ) -> Bool {
        guard pidMatches else { return false }
        if let observedIncarnation, let currentIncarnation {
            return observedIncarnation == currentIncarnation
        }
        if let fallbackLaunchDatesMatch {
            return fallbackLaunchDatesMatch
        }
        // Unknown identity is not proof of sameness. Rebinding is safer than
        // retaining an observer that may point at a recycled PID.
        return false
    }
}

/// Decides whether a workspace termination notification belongs to an older
/// process lifetime that reused the currently observed numeric PID.
enum TerminationNotificationPolicy {
    static func shouldIgnore(
        observedPIDMatches: Bool,
        launchDatesMismatch: Bool,
        terminatedAppReportsTerminated: Bool,
        liveAppIsRunning: Bool
    ) -> Bool {
        guard observedPIDMatches else { return false }
        if launchDatesMismatch { return true }
        // A terminated notification and a currently-running lookup for the same
        // numeric PID cannot both describe the session we should tear down. This
        // also covers the ordering where the replacement process was attached
        // before the old notification arrived: observed and live incarnations
        // are then equal because both refer to the replacement. Ignoring is safe
        // for a briefly queryable dying process too; the activation transition
        // will rebind/clear it, whereas destroying a live replacement is not
        // recoverable until another workspace event occurs.
        return terminatedAppReportsTerminated && liveAppIsRunning
    }
}

/// Attempt accounting must also terminate a synchronous no-op that cannot
/// satisfy the tile target (for example, an already-anchored non-resizable
/// window). Busy requests and already-satisfied preflights consume nothing.
enum TileAttemptAccountingPolicy {
    static func shouldCount(
        startResult: WindowAnimationStartResult,
        targetSatisfied: Bool
    ) -> Bool {
        switch startResult {
        case .started:
            return true
        case .completedSynchronously:
            return !targetSatisfied
        case .busy:
            return false
        }
    }
}

/// Identifies one observed application activation.
///
/// A PID alone is not a stable session identity because macOS can reuse it after
/// a process exits. The generation changes on every activation, including when
/// the same PID is activated again.
struct LayoutActivationToken: Hashable, Sendable {
    let pid: Int32
    let generation: UInt64

    init(pid: Int32, generation: UInt64) {
        self.pid = pid
        self.generation = generation
    }
}

/// Creates and validates activation-scoped tokens.
///
/// This is intentionally a pure value type. Its owner is responsible for
/// serializing access (the eventual runtime integration is expected to own it
/// on the main actor).
struct LayoutActivationTracker: Sendable {
    private var latestGeneration: UInt64 = 0
    private(set) var currentToken: LayoutActivationToken?

    init() {}

    /// Starts a new activation session. Every call produces a fresh generation,
    /// even if `pid` is the same as the current or a previously invalidated PID.
    mutating func activate(pid: Int32) -> LayoutActivationToken {
        precondition(latestGeneration < .max, "Layout activation generation exhausted")
        latestGeneration += 1

        let token = LayoutActivationToken(pid: pid, generation: latestGeneration)
        currentToken = token
        return token
    }

    /// Invalidates whichever activation is current.
    mutating func invalidate() {
        currentToken = nil
    }

    /// Invalidates only when `token` still owns the current activation. This
    /// guarded form lets asynchronous teardown from an old activation become a
    /// no-op instead of invalidating a newer session.
    @discardableResult
    mutating func invalidate(_ token: LayoutActivationToken) -> Bool {
        guard isCurrent(token) else { return false }
        currentToken = nil
        return true
    }

    func isCurrent(_ token: LayoutActivationToken) -> Bool {
        currentToken == token
    }
}

/// Geometry-writing operation types coordinated by the single-flight state.
enum LayoutOperationKind: Hashable, Sendable {
    case center
    case tile
}

/// Stable identity for one activation-scoped window operation.
struct LayoutOperationID: Hashable, Sendable {
    let token: LayoutActivationToken
    let windowKey: String
    let kind: LayoutOperationKind
    /// Distinguishes a later operation for the same window/session from a
    /// completed earlier one (ABA protection for delayed completions).
    let sequence: UInt64

    init(
        token: LayoutActivationToken,
        windowKey: String,
        kind: LayoutOperationKind,
        sequence: UInt64 = 0
    ) {
        self.token = token
        self.windowKey = windowKey
        self.kind = kind
        self.sequence = sequence
    }
}

/// Unique ownership token for one scheduled continuation/timer generation.
/// Even two timers for the same activation and operation receive different
/// sequences, so an already-queued old handler cannot clear the replacement's
/// shared timer slot.
struct LayoutContinuationLease: Hashable, Sendable {
    let token: LayoutActivationToken
    let sequence: UInt64
    let operationID: LayoutOperationID?
    let windowKey: String?
}

/// Pure single-flight state for geometry-writing operations.
///
/// The state owns no timer and performs no effects. It only decides which
/// operation may run. Exactly one operation is active; additional distinct
/// operations wait in stable FIFO order.
struct LayoutSingleFlightState: Sendable {
    enum SubmissionResult: Equatable, Sendable {
        case started
        case queued
        case duplicate
    }

    enum CompletionResult: Equatable, Sendable {
        case ignored
        case completed(next: LayoutOperationID?)
    }

    private(set) var active: LayoutOperationID?
    private(set) var queued: [LayoutOperationID] = []

    init() {}

    /// Starts immediately when idle, otherwise appends in FIFO order. An exact
    /// operation already active or queued is never inserted twice.
    @discardableResult
    mutating func submit(_ operation: LayoutOperationID) -> SubmissionResult {
        guard active != operation, !queued.contains(operation) else {
            return .duplicate
        }

        guard active != nil else {
            active = operation
            return .started
        }

        queued.append(operation)
        return .queued
    }

    /// Completes only the exact active operation. Stale or out-of-order
    /// completion callbacks leave both the active slot and queue untouched.
    /// A valid completion promotes the oldest queued operation.
    @discardableResult
    mutating func complete(_ operation: LayoutOperationID) -> CompletionResult {
        guard active == operation else { return .ignored }

        let next = queued.isEmpty ? nil : queued.removeFirst()
        active = next
        return .completed(next: next)
    }

    /// Cancels the active operation and all queued work without promoting any
    /// item. The runtime owner remains responsible for cancelling real effects.
    mutating func cancelAll() {
        active = nil
        queued.removeAll(keepingCapacity: false)
    }
}

/// A single async resource slot with explicit ownership.
///
/// Cleanup from an unrelated PID/session must not cancel the current owner's
/// timer. Keeping this as pure state makes that lifecycle rule testable.
struct OwnedOperationState<Owner: Equatable> {
    private(set) var owner: Owner?

    @discardableResult
    mutating func begin(owner newOwner: Owner) -> Owner? {
        let previous = owner
        owner = newOwner
        return previous
    }

    mutating func end(ifOwnedBy expectedOwner: Owner) -> Bool {
        guard owner == expectedOwner else { return false }
        owner = nil
        return true
    }

    mutating func reset() {
        owner = nil
    }
}

/// The multi-key counterpart of `OwnedOperationState`. Each window can own one
/// independent continuation while stale cleanup remains exact-key/exact-owner.
struct MultiOwnedOperationState<Key: Hashable, Owner: Equatable> {
    private(set) var owners: [Key: Owner] = [:]

    var keys: Set<Key> { Set(owners.keys) }

    func owner(for key: Key) -> Owner? {
        owners[key]
    }

    func owns(_ owner: Owner, for key: Key) -> Bool {
        owners[key] == owner
    }

    @discardableResult
    mutating func begin(owner: Owner, for key: Key) -> Owner? {
        owners.updateValue(owner, forKey: key)
    }

    mutating func end(ifOwnedBy owner: Owner, for key: Key) -> Bool {
        guard owners[key] == owner else { return false }
        owners.removeValue(forKey: key)
        return true
    }

    mutating func reset() {
        owners.removeAll(keepingCapacity: false)
    }
}

/// Typed outcome for one observer decision. Only `.retry` keeps the bounded
/// activation polling loop alive.
enum HandleOutcome: Equatable {
    case completed
    case retry
    case ignored

    var shouldContinueInitialRetry: Bool {
        self == .retry
    }
}
