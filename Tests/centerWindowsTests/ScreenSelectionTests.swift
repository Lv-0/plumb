import CoreGraphics
import Testing
@testable import centerWindows

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
