import CoreGraphics
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 瞬态窗口判据测试
//
// 验证：looksLikeTransientWindow 的纯几何判据 isTransient 在各种窗口尺寸下都正确，
// 决定居中路径是否锁定 PID（登录窗/splash 不锁，真正主窗口才锁）。
// 覆盖：WeChat 登录窗（~5%）、splash、中等窗、近满屏窗、零/负屏、边界。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func transient_smallLoginWindow_isTransient() async throws {
    // WeChat 登录窗 280×380 在 1920×1050 可用区上 → 5.3% < 0.5 → 瞬态（不锁 PID）。
    let login = CGSize(width: 280, height: 380)
    let visibleArea: CGFloat = 1920 * 1050
    #expect(TransientDetector.isTransient(size: login, largestVisibleFrameArea: visibleArea) == true)
}

@Test
func transient_nearFullscreen_isNotTransient() async throws {
    // 真正主窗口接近满屏（>90%）→ 非瞬态 → 正常锁 PID。
    let main = CGSize(width: 1880, height: 1030)
    let visibleArea: CGFloat = 1920 * 1050
    #expect(TransientDetector.isTransient(size: main, largestVisibleFrameArea: visibleArea) == false)
}

@Test
func transient_mediumWindow_isTransient() async throws {
    // 中等窗（800×600 ≈ 22% on 1920×1050）→ 仍 < 0.5 → 瞬态。
    // 这安全：判瞬态只意味着"不锁 PID 让 retry 继续"，retry 会在窗口到达最终态后锁。
    let medium = CGSize(width: 800, height: 600)
    let visibleArea: CGFloat = 1920 * 1050
    #expect(TransientDetector.isTransient(size: medium, largestVisibleFrameArea: visibleArea) == true)
}

@Test
func transient_halfAreaBoundary_isNotTransient() async throws {
    // 面积比恰好 == 阈值 0.5 → 非瞬态（严格小于才瞬态）。
    let half = CGSize(width: 960, height: 1050)  // 960×1050 / 1920×1050 = 0.5
    let visibleArea: CGFloat = 1920 * 1050
    #expect(TransientDetector.isTransient(size: half, largestVisibleFrameArea: visibleArea) == false)
}

@Test
func transient_slightlyUnderHalf_isTransient() async throws {
    // 面积比略低于 0.5 → 瞬态。
    let justUnder = CGSize(width: 959, height: 1050)
    let visibleArea: CGFloat = 1920 * 1050
    #expect(TransientDetector.isTransient(size: justUnder, largestVisibleFrameArea: visibleArea) == true)
}

@Test
func transient_zeroVisibleArea_isNotTransient() async throws {
    // 无可用屏信息（visibleArea=0）→ 保守返回 false（非瞬态 → 正常锁），避免无限重试。
    #expect(TransientDetector.isTransient(size: CGSize(width: 100, height: 100), largestVisibleFrameArea: 0) == false)
}

@Test
func transient_externalLargerScreen_usedAsDenominator() async throws {
    // 多屏：用最大屏的 visibleFrame 作分母。WeChat 登录窗在主屏，外接屏更大 →
    // 分母用外接屏，登录窗占比更低 → 仍瞬态。
    let login = CGSize(width: 280, height: 380)
    let largestVisibleArea: CGFloat = 3840 * 2100  // 外接 4K 屏（缩放后）
    #expect(TransientDetector.isTransient(size: login, largestVisibleFrameArea: largestVisibleArea) == true)
}

@Test
func transient_thresholdConstant_isHalf() async throws {
    #expect(TransientDetector.coverageThreshold == 0.5)
}
