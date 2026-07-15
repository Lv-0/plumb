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
func cgWindowFallbackSelectsCurrentDocumentInsteadOfAlreadyTiledSibling() {
    let tiledSibling = CGRect(x: 16, y: 43, width: 1_480, height: 847)
    let currentDocument = CGRect(x: 263, y: 33, width: 1_051, height: 867)

    let selected = CGWindowGeometryFallbackSelection.select(
        candidates: [tiledSibling, currentDocument],
        expectedSize: currentDocument.size,
        preferredDisplayBounds: nil
    )

    #expect(selected == currentDocument)
}

@Test
func cgWindowFallbackFailsClosedForEqualSizeSiblings() {
    let first = CGRect(x: 120, y: 80, width: 1_051, height: 867)
    let second = CGRect(x: 263, y: 33, width: 1_051, height: 867)

    let selected = CGWindowGeometryFallbackSelection.select(
        candidates: [first, second],
        expectedSize: first.size,
        preferredDisplayBounds: nil
    )

    #expect(selected == nil)
}

@Test
func cgWindowFallbackKeepsUniqueSingleWindowEvidence() {
    let onlyWindow = CGRect(x: 263, y: 33, width: 1_051, height: 867)

    let selected = CGWindowGeometryFallbackSelection.select(
        candidates: [onlyWindow],
        expectedSize: onlyWindow.size,
        preferredDisplayBounds: nil
    )

    #expect(selected == onlyWindow)
}

@Test
func cgWindowFallbackUsesPreferredDisplayToBreakSameSizeTie() {
    let preferredDisplay = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    let preferredWindow = CGRect(x: 263, y: 33, width: 1_051, height: 867)
    let otherDisplayWindow = CGRect(x: 1_700, y: 33, width: 1_051, height: 867)

    let selected = CGWindowGeometryFallbackSelection.select(
        candidates: [otherDisplayWindow, preferredWindow],
        expectedSize: preferredWindow.size,
        preferredDisplayBounds: preferredDisplay
    )

    #expect(selected == preferredWindow)
}

@Test
func acceptedTileFallbackRequiresWriterRecord() {
    var store = AcceptedTileFallbackStore()
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let constrained = CGRect(x: 16, y: 10, width: 1888, height: 1050)

    let acceptedBeforeRecord = store.accepts(
        key: "101:7:ax:70",
        pid: 101,
        targetFrame: target,
        currentFrame: constrained
    )
    let didRecord = store.record(
        key: "101:7:ax:70",
        pid: 101,
        targetFrame: target,
        acceptedFrame: constrained,
        reason: .writerProduced
    )
    let acceptedAfterRecord = store.accepts(
        key: "101:7:ax:70",
        pid: 101,
        targetFrame: target,
        currentFrame: constrained
    )

    #expect(acceptedBeforeRecord == false)
    #expect(didRecord)
    #expect(acceptedAfterRecord)
}

@Test
func acceptedTileFallbackRejectsChangedTargetOrFrame() {
    var targetStore = AcceptedTileFallbackStore()
    let target = CGRect(x: 144, y: 162, width: 1224, height: 707)
    let constrained = CGRect(x: 144, y: 162, width: 1224, height: 752)
    let didRecordTarget = targetStore.record(
        key: "202:8:ax:80",
        pid: 202,
        targetFrame: target,
        acceptedFrame: constrained,
        reason: .writerProduced
    )

    let acceptedChangedTarget = targetStore.accepts(
        key: "202:8:ax:80",
        pid: 202,
        targetFrame: target.insetBy(dx: 1, dy: 1),
        currentFrame: constrained
    )
    let acceptedOriginalTargetAfterWrongProbe = targetStore.accepts(
        key: "202:8:ax:80",
        pid: 202,
        targetFrame: target,
        currentFrame: constrained
    )

    var frameStore = AcceptedTileFallbackStore()
    let didRecordFrame = frameStore.record(
        key: "202:8:ax:80",
        pid: 202,
        targetFrame: target,
        acceptedFrame: constrained,
        reason: .writerProduced
    )
    let acceptedChangedFrame = frameStore.accepts(
        key: "202:8:ax:80",
        pid: 202,
        targetFrame: target,
        currentFrame: constrained.offsetBy(dx: 0, dy: 10)
    )

    #expect(didRecordTarget)
    #expect(acceptedChangedTarget == false)
    #expect(acceptedOriginalTargetAfterWrongProbe)
    #expect(didRecordFrame)
    #expect(acceptedChangedFrame == false)
}

@Test
func acceptedTileFallbackInvalidatesOnlyTerminatedPID() {
    var store = AcceptedTileFallbackStore()
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let constrained = CGRect(x: 16, y: 10, width: 1888, height: 1050)
    let didRecordFirst = store.record(
        key: "101:7:ax:70",
        pid: 101,
        targetFrame: target,
        acceptedFrame: constrained,
        reason: .writerProduced
    )
    let didRecordSecond = store.record(
        key: "202:8:ax:80",
        pid: 202,
        targetFrame: target,
        acceptedFrame: constrained,
        reason: .writerProduced
    )

    store.invalidate(pid: 101)
    let secondStillAccepted = store.accepts(
        key: "202:8:ax:80",
        pid: 202,
        targetFrame: target,
        currentFrame: constrained
    )

    #expect(didRecordFirst)
    #expect(didRecordSecond)
    #expect(store.count == 1)
    #expect(secondStillAccepted)
}

@Test
func animationSlotRejectsDifferentWindowWhileBusy() {
    var slot = WindowAnimationSlot()
    let firstOwner = WindowAnimationOwner(pid: 101, windowIdentity: "1:ax:10")
    let secondOwner = WindowAnimationOwner(pid: 202, windowIdentity: "2:ax:20")
    let first = slot.acquire(key: "101:1:tile", owner: firstOwner)

    #expect(first != nil)
    #expect(slot.acquire(key: "202:2:center", owner: secondOwner) == nil)
    #expect(slot.activeKey == "101:1:tile")
    #expect(slot.activeOwner == firstOwner)
}

@Test
func staleAnimationLeaseCannotReleaseNewSameWindowRequest() {
    var slot = WindowAnimationSlot()
    let owner = WindowAnimationOwner(pid: 101, windowIdentity: "1:ax:10")
    let stale = slot.acquire(key: "101:1:tile", owner: owner)!
    slot.cancel()
    let current = slot.acquire(key: "101:1:tile", owner: owner)!

    let staleReleased = slot.release(stale)
    #expect(!staleReleased)
    #expect(slot.activeLease == current)
    let currentReleased = slot.release(current)
    #expect(currentReleased)
    #expect(slot.activeLease == nil)
}

@Test
func phaseBAnchorDriftRequiresSustainedDisplacement() {
    var monitor = FixedAnchorDriftMonitor(threshold: 40, requiredSamples: 4)
    let expected = CGPoint(x: 16, y: 890)
    let displaced = CGPoint(x: 70, y: 200)

    let first = monitor.observesUserDrift(position: displaced, expectedPosition: expected)
    let second = monitor.observesUserDrift(position: displaced, expectedPosition: expected)
    let third = monitor.observesUserDrift(position: displaced, expectedPosition: expected)
    let fourth = monitor.observesUserDrift(position: displaced, expectedPosition: expected)
    #expect(!first)
    #expect(!second)
    #expect(!third)
    #expect(fourth)
}

@Test
func phaseBAnchorDriftResetsAfterWriterAlignedReadback() {
    var monitor = FixedAnchorDriftMonitor(threshold: 40, requiredSamples: 2)
    let expected = CGPoint(x: 16, y: 890)
    let displaced = CGPoint(x: 70, y: 200)
    let aligned = CGPoint(x: 16, y: 890)

    let first = monitor.observesUserDrift(position: displaced, expectedPosition: expected)
    let alignedReadback = monitor.observesUserDrift(position: aligned, expectedPosition: expected)
    let afterReset = monitor.observesUserDrift(position: displaced, expectedPosition: expected)
    #expect(!first)
    #expect(!alignedReadback)
    #expect(!afterReset)
}

@Test
func phaseBAnchorTrajectoryAcceptsBothLegalSizeChangeReadbacksInAllCoordinateSpaces() {
    let screenFrame = CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
    let primaryTopY: CGFloat = 900
    let topLeftGlobal = CGPoint(x: 1_500, y: 1_000)
    let resizedWindow = CGSize(width: 800, height: 800)

    for space in WindowCoordinateSpace.allCases {
        let fixedRawOrigin: CGPoint
        let physicalTopLeftRawOrigin: CGPoint
        switch space {
        case .globalBottomLeft:
            fixedRawOrigin = CGPoint(x: 1_500, y: 600)
            physicalTopLeftRawOrigin = CGPoint(x: 1_500, y: 200)
        case .globalTopLeft:
            fixedRawOrigin = CGPoint(x: 1_500, y: -100)
            physicalTopLeftRawOrigin = fixedRawOrigin
        case .localBottomLeft:
            fixedRawOrigin = CGPoint(x: 60, y: 600)
            physicalTopLeftRawOrigin = CGPoint(x: 60, y: 200)
        case .localTopLeft:
            fixedRawOrigin = CGPoint(x: 60, y: 80)
            physicalTopLeftRawOrigin = fixedRawOrigin
        }

        let trajectory = PhaseBAnchorTrajectory(
            fixedRawOrigin: fixedRawOrigin,
            topLeftGlobal: topLeftGlobal,
            screenFrame: screenFrame,
            space: space,
            primaryTopY: primaryTopY
        )
        let expected = trajectory.expectedRawOrigins(currentSize: resizedWindow)
        #expect(expected.contains(fixedRawOrigin))
        #expect(expected.contains(physicalTopLeftRawOrigin))

        var fixedMonitor = FixedAnchorDriftMonitor(threshold: 40, requiredSamples: 2)
        let firstFixedSample = fixedMonitor.observesUserDrift(
            position: fixedRawOrigin,
            expectedPositions: expected
        )
        let secondFixedSample = fixedMonitor.observesUserDrift(
            position: fixedRawOrigin,
            expectedPositions: expected
        )
        #expect(!firstFixedSample)
        #expect(!secondFixedSample)

        var physicalMonitor = FixedAnchorDriftMonitor(threshold: 40, requiredSamples: 2)
        let firstPhysicalSample = physicalMonitor.observesUserDrift(
            position: physicalTopLeftRawOrigin,
            expectedPositions: expected
        )
        let secondPhysicalSample = physicalMonitor.observesUserDrift(
            position: physicalTopLeftRawOrigin,
            expectedPositions: expected
        )
        #expect(!firstPhysicalSample)
        #expect(!secondPhysicalSample)

        let displaced = CGPoint(
            x: physicalTopLeftRawOrigin.x + 100,
            y: physicalTopLeftRawOrigin.y + 100
        )
        var driftMonitor = FixedAnchorDriftMonitor(threshold: 40, requiredSamples: 2)
        let firstDriftSample = driftMonitor.observesUserDrift(
            position: displaced,
            expectedPositions: expected
        )
        let secondDriftSample = driftMonitor.observesUserDrift(
            position: displaced,
            expectedPositions: expected
        )
        #expect(!firstDriftSample)
        #expect(secondDriftSample)
    }
}

@Test
func phaseBAnchorDriftEvidenceSurvivesPreciseRewriteHandoffs() {
    let expected = [CGPoint(x: 16, y: 890)]
    let displaced = CGPoint(x: 100, y: 200)
    var handedOff = FixedAnchorDriftMonitor(threshold: 40, requiredSamples: 3)

    for attempt in 1 ... 3 {
        var currentAttempt = handedOff
        let interrupted = currentAttempt.observesUserDrift(
            position: displaced,
            expectedPositions: expected
        )
        handedOff = currentAttempt
        #expect(interrupted == (attempt == 3))
    }
}

@Test
func localCoordinatesPreferCurrentHorizontalSecondaryScreen() {
    let screens = [
        CGRect(x: 0, y: 0, width: 1_440, height: 900),
        CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
    ]
    let match = WindowCoordinateContextSelection.bestMatch(
        rawPosition: CGPoint(x: 100, y: 100),
        windowSize: CGSize(width: 800, height: 600),
        screenFrames: screens,
        primaryTopY: 900,
        preferredScreenIndex: 1
    )

    #expect(match?.screenIndex == 1)
    #expect(match?.space == .localTopLeft)
    #expect(match?.globalRect == CGRect(x: 1_540, y: 380, width: 800, height: 600))
}

@Test
func localCoordinatesPreferCurrentVerticallyStackedScreen() {
    let screens = [
        CGRect(x: 0, y: 0, width: 1_440, height: 900),
        CGRect(x: 0, y: 900, width: 1_600, height: 1_000),
    ]
    let match = WindowCoordinateContextSelection.bestMatch(
        rawPosition: CGPoint(x: 120, y: 80),
        windowSize: CGSize(width: 900, height: 600),
        screenFrames: screens,
        primaryTopY: 900,
        preferredScreenIndex: 1
    )

    #expect(match?.screenIndex == 1)
    #expect(match?.space == .localTopLeft)
    #expect(match?.globalRect == CGRect(x: 120, y: 1_220, width: 900, height: 600))
}

@Test
func localCoordinatesPreferNegativeOriginScreen() {
    let screens = [
        CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
        CGRect(x: 0, y: 0, width: 1_440, height: 900),
    ]
    let match = WindowCoordinateContextSelection.bestMatch(
        rawPosition: CGPoint(x: 140, y: 90),
        windowSize: CGSize(width: 900, height: 600),
        screenFrames: screens,
        primaryTopY: 900,
        preferredScreenIndex: 0
    )

    #expect(match?.screenIndex == 0)
    #expect(match?.space == .localTopLeft)
    #expect(match?.globalRect == CGRect(x: -1_780, y: 390, width: 900, height: 600))
}

@Test
func localCoordinatesWithoutAnyScreenSignalRemainAmbiguous() {
    let screens = [
        CGRect(x: 0, y: 0, width: 1_440, height: 900),
        CGRect(x: 1_440, y: 0, width: 1_440, height: 900),
    ]
    let match = WindowCoordinateContextSelection.bestMatch(
        rawPosition: CGPoint(x: 100, y: 100),
        windowSize: CGSize(width: 800, height: 600),
        screenFrames: screens,
        primaryTopY: 900
    )

    #expect(match == nil)
}

@Test
func globalNegativeCoordinatesRemainUnambiguousWithoutPreference() {
    let screens = [
        CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
        CGRect(x: 0, y: 0, width: 1_440, height: 900),
    ]
    let match = WindowCoordinateContextSelection.bestMatch(
        rawPosition: CGPoint(x: -1_700, y: 100),
        windowSize: CGSize(width: 900, height: 600),
        screenFrames: screens,
        primaryTopY: 900
    )

    #expect(match?.screenIndex == 0)
    #expect(match?.space == .globalTopLeft)
}

@Test
func animationOwnerUsesWindowNumberAcrossAXRewrapping() {
    let first = WindowAnimationOwner.resolved(pid: 101, windowNumber: 77, fallbackAXHash: 1_001)
    let rewrapped = WindowAnimationOwner.resolved(pid: 101, windowNumber: 77, fallbackAXHash: 9_999)
    let otherWindow = WindowAnimationOwner.resolved(pid: 101, windowNumber: 78, fallbackAXHash: 1_001)

    #expect(first == rewrapped)
    #expect(first != otherWindow)
}

@Test
func animationOwnerFallsBackToAXHashWithoutWindowNumber() {
    let first = WindowAnimationOwner.resolved(pid: 101, windowNumber: nil, fallbackAXHash: 1_001)
    let same = WindowAnimationOwner.resolved(pid: 101, windowNumber: nil, fallbackAXHash: 1_001)
    let other = WindowAnimationOwner.resolved(pid: 101, windowNumber: nil, fallbackAXHash: 2_002)

    #expect(first == same)
    #expect(first != other)
}

@Test
func stateIdentityUsesWindowNumberAcrossAXRewrapping() {
    let first = WindowStateIdentity.key(pid: 101, windowNumber: 77, fallbackAXHash: 1_001)
    let rewrapped = WindowStateIdentity.key(pid: 101, windowNumber: 77, fallbackAXHash: 9_999)
    let otherWindow = WindowStateIdentity.key(pid: 101, windowNumber: 78, fallbackAXHash: 1_001)

    #expect(first == rewrapped)
    #expect(first != otherWindow)
    #expect(first.hasPrefix("101:"))
}

@Test
func stateIdentityFallsBackToAXHashWithoutWindowNumber() {
    let first = WindowStateIdentity.key(pid: 101, windowNumber: nil, fallbackAXHash: 1_001)
    let same = WindowStateIdentity.key(pid: 101, windowNumber: nil, fallbackAXHash: 1_001)
    let other = WindowStateIdentity.key(pid: 101, windowNumber: nil, fallbackAXHash: 2_002)

    #expect(first == same)
    #expect(first != other)
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
