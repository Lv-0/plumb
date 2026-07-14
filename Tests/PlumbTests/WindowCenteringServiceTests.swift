import CoreGraphics
import Testing
@testable import Plumb

@Test(arguments: [WindowAnimator.Outcome.writerFailed, .userInterrupted])
func unsuccessfulPhaseAOutcomeNeverEntersPhaseB(_ outcome: WindowAnimator.Outcome) {
    #expect(!TilePhaseAOutcomePolicy.shouldEnterPhaseB(after: outcome))
}

@Test
func onlyFinishedPhaseAOutcomeEntersPhaseB() {
    #expect(TilePhaseAOutcomePolicy.shouldEnterPhaseB(after: .finished))
}

@Test
func processScopedCacheInvalidatesOnlyRequestedPID() {
    var cache = ProcessScopedCache<String>()
    cache[101] = "first"
    cache[202] = "second"

    #expect(cache.removeValue(for: 101) == "first")
    #expect(cache[101] == nil)
    #expect(cache[202] == "second")
    #expect(cache.count == 1)
}

@Test
func processScopedCacheCanInvalidateAllProcesses() {
    var cache = ProcessScopedCache<Int>()
    cache[101] = 1
    cache[202] = 2

    cache.removeAll()

    #expect(cache[101] == nil)
    #expect(cache[202] == nil)
    #expect(cache.count == 0)
}

@Test
func animationSlotRejectsDifferentWindowWhileBusy() {
    var slot = WindowAnimationSlot()
    let first = slot.acquire(key: "101:1:tile")

    #expect(first != nil)
    #expect(slot.acquire(key: "202:2:center") == nil)
    #expect(slot.activeKey == "101:1:tile")
}

@Test
func staleAnimationLeaseCannotReleaseNewSameWindowRequest() {
    var slot = WindowAnimationSlot()
    let stale = slot.acquire(key: "101:1:tile")!
    slot.cancel()
    let current = slot.acquire(key: "101:1:tile")!

    let staleReleased = slot.release(stale)
    #expect(!staleReleased)
    #expect(slot.activeLease == current)
    let currentReleased = slot.release(current)
    #expect(currentReleased)
    #expect(slot.activeLease == nil)
}

@Test
func screenOverlapSelectionRejectsAllZeroOverlap() {
    let screens = [
        CGRect(x: 0, y: 0, width: 100, height: 100),
        CGRect(x: 100, y: 0, width: 100, height: 100),
    ]

    let match = WindowScreenOverlapSelection.bestMatch(
        for: CGRect(x: 500, y: 500, width: 40, height: 40),
        in: screens
    )

    #expect(match == nil)
}

@Test
func screenOverlapSelectionChoosesLargestPositiveOverlap() {
    let screens = [
        CGRect(x: 0, y: 0, width: 100, height: 100),
        CGRect(x: 100, y: 0, width: 100, height: 100),
    ]

    let match = WindowScreenOverlapSelection.bestMatch(
        for: CGRect(x: 80, y: 10, width: 80, height: 50),
        in: screens
    )

    #expect(match?.index == 1)
    #expect(match?.area == 3_000)
}

@Test
func screenOverlapSelectionUsesCenterToBreakEqualOverlapTie() {
    let screens = [
        CGRect(x: 0, y: 0, width: 100, height: 100),
        CGRect(x: 100, y: 0, width: 100, height: 100),
    ]

    let match = WindowScreenOverlapSelection.bestMatch(
        for: CGRect(x: 50, y: 10, width: 100, height: 50),
        in: screens
    )

    // The center lies on the second screen's inclusive minX edge.
    #expect(match?.index == 1)
    #expect(match?.area == 2_500)
}

@Test
func screenOverlapSelectionDoesNotLetZeroAreaWinToleranceTie() {
    let screens = [
        CGRect(x: 0, y: 0, width: 100, height: 100),
        CGRect(x: 100, y: 0, width: 100, height: 100),
    ]

    let match = WindowScreenOverlapSelection.bestMatch(
        for: CGRect(x: 199.75, y: 10, width: 1, height: 1),
        in: screens
    )

    #expect(match?.index == 1)
    #expect(match?.area == 0.25)
}
