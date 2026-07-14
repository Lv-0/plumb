import Foundation
import Testing
@testable import Plumb

private final class LockedTestValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

@Test("cancelling Accessibility polling suppresses a later grant callback")
func cancellingAccessibilityPollingSuppressesCallback() async {
    let trusted = LockedTestValue(false)
    let callbacks = LockedTestValue(0)
    let handle = AccessibilityPermission.awaitTrusted(
        timeout: 1,
        interval: 0.01,
        trustCheck: { trusted.value },
        onGranted: { callbacks.set(callbacks.value + 1) }
    )

    #expect(handle.isActive)
    handle.cancel()
    trusted.set(true)
    try? await Task.sleep(nanoseconds: 80_000_000)

    #expect(!handle.isActive)
    #expect(callbacks.value == 0)
}

@Test("Accessibility polling grants once and becomes terminal")
func accessibilityPollingGrantsExactlyOnce() async {
    let trusted = LockedTestValue(false)
    let callbacks = LockedTestValue(0)
    let handle = AccessibilityPermission.awaitTrusted(
        timeout: 1,
        interval: 0.01,
        trustCheck: { trusted.value },
        onGranted: { callbacks.set(callbacks.value + 1) }
    )

    trusted.set(true)
    try? await Task.sleep(nanoseconds: 80_000_000)

    #expect(!handle.isActive)
    #expect(callbacks.value == 1)
}
