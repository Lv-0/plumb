import Foundation

/// Process-wide verdict for the opt-in GUI/AX self-test harnesses.
///
/// Harnesses historically printed `FAIL`/`CHECK` while `main.swift` always returned 0.
/// Keeping the verdict here lets the existing detailed logs remain the source of truth while
/// still giving scripts and release gates a reliable process exit status.
@MainActor
enum SelfTestOutcome {
    private(set) static var failureMessages: [String] = []

    static func reset() {
        failureMessages.removeAll(keepingCapacity: true)
    }

    static func observe(_ message: String) {
        if message.contains("FAIL") || message.contains("CHECK") {
            failureMessages.append(message)
        }
    }

    static func recordFailure(_ message: String) {
        failureMessages.append(message)
    }

    static var exitCode: Int32 {
        failureMessages.isEmpty ? 0 : 1
    }
}
