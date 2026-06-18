import CoreGraphics
import Testing
@testable import Plumb

@Test
func centerWindowInVisibleFrame() async throws {
    let frame = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let windowSize = CGSize(width: 800, height: 600)

    let origin = WindowGeometry.centeredOrigin(windowSize: windowSize, visibleFrame: frame)

    #expect(origin.x == 320)
    #expect(origin.y == 163)
}

@Test
func clampWhenWindowLargerThanVisibleFrame() async throws {
    let frame = CGRect(x: 100, y: 50, width: 700, height: 500)
    let windowSize = CGSize(width: 1200, height: 900)

    let origin = WindowGeometry.centeredOrigin(windowSize: windowSize, visibleFrame: frame)

    // Best-effort centering even when the window cannot fully fit into the visible frame.
    #expect(origin.x == -150)
    #expect(origin.y == -150)
}
