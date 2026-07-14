import CoreGraphics
import Testing
@testable import Plumb

@Test
func selfTestSelectionSkipsDialogBeforeStandardDocumentWindow() {
    let candidates = [
        SelfTestWindowDescriptor(
            role: "AXWindow",
            subrole: "AXDialog",
            size: CGSize(width: 66, height: 20),
            isMinimized: false,
            isModal: false
        ),
        SelfTestWindowDescriptor(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            size: CGSize(width: 586, height: 488),
            isMinimized: false,
            isModal: false
        ),
    ]

    #expect(SelfTestWindowSelectionPolicy.preferredIndex(in: candidates) == 1)
}

@Test
func selfTestSelectionFailsWhenOnlyDialogExists() {
    let candidates = [
        SelfTestWindowDescriptor(
            role: "AXWindow",
            subrole: "AXDialog",
            size: CGSize(width: 600, height: 500),
            isMinimized: false,
            isModal: false
        ),
    ]

    #expect(SelfTestWindowSelectionPolicy.preferredIndex(in: candidates) == nil)
}

@Test
func selfTestSelectionPrefersLargestEligibleStandardWindow() {
    let candidates = [
        SelfTestWindowDescriptor(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            size: CGSize(width: 400, height: 300),
            isMinimized: false,
            isModal: false
        ),
        SelfTestWindowDescriptor(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            size: CGSize(width: 900, height: 700),
            isMinimized: false,
            isModal: false
        ),
    ]

    #expect(SelfTestWindowSelectionPolicy.preferredIndex(in: candidates) == 1)
}
