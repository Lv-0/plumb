import CoreGraphics
import Testing
@testable import Plumb

@Test
func selectByCenterWhenCenterInsideOneScreen() {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 2000, y: 500), inScreens: screens)
    #expect(idx == 1)
}

@Test
func selectByCenterPrefersPrimaryWhenCenterInPrimary() {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 720, y: 450), inScreens: screens)
    #expect(idx == 0)
}

@Test
func selectByCenterFallsBackToMaxOverlapWhenCenterOnSeam() {
    // CGRect.contains 是半开区间：x=1440 不属于屏幕0（maxX=1440 不含），
    // 但属于屏幕1（minX=1440 含）。这是几何上的正确归属，符合“中心在接缝归右侧屏”。
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 1440, y: 450), inScreens: screens)
    #expect(idx == 1)
}

@Test
func selectByCenterSingleScreen() {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 100, y: 100), inScreens: screens)
    #expect(idx == 0)
}

@Test
func selectByCenterEmptyScreensReturnsNil() {
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 100, y: 100), inScreens: [])
    #expect(idx == nil)
}

@Test
func selectByCenterCompletelyOffscreenReturnsNil() {
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    let idx = ScreenSelection.screenIndex(
        forCenter: CGPoint(x: 10_000, y: 10_000),
        inScreens: screens
    )
    #expect(idx == nil)
}

@Test
func cgOverlapUsesTopLeftDisplayCoordinatesForVerticallyStackedScreen() {
    // Current runtime topology: the external display is above/right in Cocoa, but its
    // CGDisplayBounds Y is negative. A CG window on that display must be compared with
    // the negative-Y CG bounds, never the positive-Y NSScreen.frame.
    let window = CGRect(x: 877, y: -1034, width: 1888, height: 1018)
    let externalCG = CGRect(x: 861, y: -1080, width: 1920, height: 1080)
    let externalCocoa = CGRect(x: 861, y: 982, width: 1920, height: 1080)

    #expect(ScreenSelection.hasSubstantialCGOverlap(
        windowBounds: window,
        displayBounds: externalCG
    ))
    #expect(ScreenSelection.hasSubstantialCGOverlap(
        windowBounds: window,
        displayBounds: externalCocoa
    ) == false)
}

@Test
func backgroundWindowBindingUsesExactNumberAcrossDisplays() {
    let builtIn = ScreenSelection.CGWindowDescriptor(
        number: 10,
        bounds: CGRect(x: 100, y: 100, width: 800, height: 600)
    )
    let external = ScreenSelection.CGWindowDescriptor(
        number: 11,
        bounds: CGRect(x: 900, y: -1000, width: 800, height: 600)
    )

    #expect(ScreenSelection.matchingCGWindowBounds(
        axWindowNumber: 11,
        candidates: [builtIn, external]
    ) == external.bounds)
}

@Test
func backgroundWindowBindingRejectsMissingAXWindowNumber() {
    let candidates = [
        ScreenSelection.CGWindowDescriptor(
            number: 20,
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600)
        ),
        ScreenSelection.CGWindowDescriptor(
            number: 21,
            bounds: CGRect(x: 900, y: -1000, width: 800, height: 600)
        ),
    ]

    #expect(ScreenSelection.matchingCGWindowBounds(
        axWindowNumber: nil,
        candidates: candidates
    ) == nil)
}

@Test
func backgroundWindowBindingRejectsDuplicateWindowNumbers() {
    let duplicate = ScreenSelection.CGWindowDescriptor(
        number: 30,
        bounds: CGRect(x: 100, y: 100, width: 800, height: 600)
    )
    #expect(ScreenSelection.matchingCGWindowBounds(
        axWindowNumber: 30,
        candidates: [duplicate, duplicate]
    ) == nil)
}

@Test
func insetsFromVisibleFrameComputesPerEdgeInsets() {
    let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 75, width: 1440, height: 800)
    let insets = WindowGeometry.insetsFromVisibleFrame(frame: frame, visible: visible)
    #expect(insets.left == 0)
    #expect(insets.right == 0)
    #expect(insets.bottom == 75)
    #expect(insets.top == 25)
}

// MARK: - 多屏边界场景（需求4：app 原先在哪屏就在哪屏）

@Test
func crossBoundaryWindowCenterStaysOnOriginalScreen() {
    // 主屏 [0,0,1440,900]，副屏 [1440,0,1920,1080]
    // 窗口跨边界但中心明显在副屏（x=1700）→ 必须归属副屏，不跳主屏。
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 1700, y: 540), inScreens: screens)
    #expect(idx == 1)
}

@Test
func cachedScreenIsOverriddenWhenCenterMovesToOtherScreen() {
    // 即便“上次在主屏”，只要中心点现在落在副屏，归属副屏（ScreenSelection 无状态）。
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: 2500, y: 500), inScreens: screens)
    #expect(idx == 1)
}

@Test
func differentDockPositionsDoNotAffectScreenOwnership() {
    // 选屏只看 frame；逐屏 Dock/分辨率差异由 effectiveVisibleFrame 单独处理。
    let screens = [CGRect(x: -1920, y: 0, width: 1920, height: 1080),  // 左侧副屏
                   CGRect(x: 0, y: 0, width: 1440, height: 900)]       // 主屏
    let idx = ScreenSelection.screenIndex(forCenter: CGPoint(x: -1000, y: 500), inScreens: screens)
    #expect(idx == 0)
}

@Test
func insetsFromVisibleFrameHandlesRightDock() {
    // 副屏：Dock 在右侧 → right inset 较大。
    let frame = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    let visible = CGRect(x: 1440, y: 0, width: 1830, height: 1050)  // 右边缩 90，上缩 30
    let insets = WindowGeometry.insetsFromVisibleFrame(frame: frame, visible: visible)
    #expect(insets.right == 90)
    #expect(insets.top == 30)
    #expect(insets.left == 0)
    #expect(insets.bottom == 0)
}
