import Foundation
import Testing

/// Opt-in failure canary for the test runner itself. The old pre-1.0 Testing package
/// incorrectly allowed some false binary expectations to exit zero under newer Swift.
/// Normal test runs pass; CI/release validation sets PLUMB_TEST_FAILURE_CANARY=1 and
/// requires this filtered command to exit non-zero.
@Test
func testingFrameworkFailureCanary() {
    guard ProcessInfo.processInfo.environment["PLUMB_TEST_FAILURE_CANARY"] == "1" else {
        return
    }
    #expect(true == false)
}
