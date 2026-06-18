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
