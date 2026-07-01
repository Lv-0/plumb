import CoreGraphics
import Testing
@testable import Plumb

@Test
func tiledFrameWithNormalInsets() async throws {
    let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)

    let frame = WindowGeometry.tiledFrame(visibleFrame: visible, insets: TileInsets(all: 16))

    #expect(frame.origin.x == 16)
    #expect(frame.origin.y == 41)
    #expect(frame.size.width == 1408)
    #expect(frame.size.height == 843)
}

@Test
func tiledFrameWithZeroInsets() async throws {
    let visible = CGRect(x: 10, y: 20, width: 400, height: 300)

    let frame = WindowGeometry.tiledFrame(visibleFrame: visible, insets: TileInsets.zero)

    #expect(frame == visible)
}

@Test
func tiledFrameWithHugeInsetsNeverNegative() async throws {
    let visible = CGRect(x: 100, y: 50, width: 200, height: 120)

    let frame = WindowGeometry.tiledFrame(visibleFrame: visible, insets: TileInsets(all: 500))

    #expect(frame.size.width == 1)
    #expect(frame.size.height == 1)
    #expect(frame.minX >= visible.minX)
    #expect(frame.minY >= visible.minY)
    #expect(frame.maxX <= visible.maxX)
    #expect(frame.maxY <= visible.maxY)
}

@Test
func tiledFrameMatchesReferenceNearFullscreen() async throws {
    // 对照参考图（需求3）：单窗口"近铺满"——保留菜单栏/Dock 后的可用区，
    // 窗口铺到几乎整个 visibleFrame，只留默认 16px 细边距。
    // 模拟真实 1440×900 主屏：底部 Dock(75) + 顶部菜单栏(25) 已从 visibleFrame 扣除。
    let visible = CGRect(x: 0, y: 75, width: 1440, height: 800)

    let frame = WindowGeometry.tiledFrame(visibleFrame: visible, insets: TileInsets(all: 16))

    // 近铺满：宽度占满可用区（仅两侧各 16px），高度同理。用容差比较避免 CGFloat 取整抖动。
    #expect(abs(frame.minX - 16) < 1)
    #expect(abs(frame.minY - (75 + 16)) < 1)        // 从可用区底部上抬 16px（不压到 Dock）
    #expect(abs(frame.maxX - (1440 - 16)) < 1)       // 不触右边缘
    #expect(abs(frame.maxY - (75 + 800 - 16)) < 1)  // 不触顶部菜单栏区
    // 窗口几乎占满可见区：两侧各 16px 边距下，覆盖约 93–94%。
    let coverage = (frame.width * frame.height) / (visible.width * visible.height)
    #expect(coverage > 0.90)
}

@Test
func tiledFramePerScreenIndependentOfDockPosition() async throws {
    // 需求4：不同屏幕逐屏计算。主屏 Dock 在底部，副屏 Dock 在右侧，
    // 两条 visibleFrame 各自扣除了自己的 Dock/菜单栏，平铺按各自可用区算。
    let primaryVisible = CGRect(x: 0, y: 75, width: 1440, height: 800)     // 主屏：底部 Dock
    let secondaryVisible = CGRect(x: 1440, y: 25, width: 1830, height: 1050) // 副屏：右侧 Dock

    let primaryFrame = WindowGeometry.tiledFrame(visibleFrame: primaryVisible, insets: TileInsets(all: 16))
    let secondaryFrame = WindowGeometry.tiledFrame(visibleFrame: secondaryVisible, insets: TileInsets(all: 16))

    // 主屏平铺落在主屏可用区内，副屏平铺落在副屏可用区内——互不串屏。
    #expect(primaryFrame.maxX <= primaryVisible.maxX)
    #expect(secondaryFrame.minX >= secondaryVisible.minX)
    #expect(primaryFrame.width != secondaryFrame.width) // 不同屏尺寸 → 不同铺满宽度
}

@Test
func tiledFrameAsymmetricInsetsPerSide() async throws {
    // 四向独立：不同方向间距 → 各边内缩不同。
    // visibleFrame 为左下原点坐标系：bottom 加到 minY、top 从高度里扣。
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    let insets = TileInsets(top: 8, bottom: 40, left: 16, right: 24)
    let frame = WindowGeometry.tiledFrame(visibleFrame: visible, insets: insets)

    #expect(abs(frame.minX - 16) == 0)                    // left
    #expect(abs(frame.minY - 40) == 0)                    // bottom
    #expect(abs(frame.width - (1000 - 16 - 24)) == 0)     // width - left - right = 960
    #expect(abs(frame.height - (800 - 8 - 40)) == 0)      // height - top - bottom = 752
    #expect(abs(frame.maxX - (1000 - 24)) == 0)           // 右边界 = 1000 - right = 976
    #expect(abs(frame.maxY - (800 - 8)) == 0)             // 上边界 = 800 - top = 792
}

@Test
func tiledFrameAsymmetricInsetsClampPerSide() async throws {
    // 巨大不对称 insets：单侧 clamp 到 (dim-1)/2，仍保证不塌缩到 <1px。
    let visible = CGRect(x: 0, y: 0, width: 200, height: 120)

    let insets = TileInsets(top: 500, bottom: 500, left: 500, right: 500)
    let frame = WindowGeometry.tiledFrame(visibleFrame: visible, insets: insets)

    // 单侧 clamp 到 (200-1)/2 = 99.5（宽）与 (120-1)/2 = 59.5（高），各轴两侧和 ≤ dim-1。
    #expect(frame.size.width >= 1)
    #expect(frame.size.height >= 1)
    #expect(frame.minX >= visible.minX)
    #expect(frame.maxX <= visible.maxX)
    #expect(frame.minY >= visible.minY)
    #expect(frame.maxY <= visible.maxY)
}

@Test
func tiledFrameNegativeInsetsClampedToZero() async throws {
    // 负 insets 应被 clamp 到 0，不外扩到 visibleFrame 之外。
    let visible = CGRect(x: 0, y: 0, width: 400, height: 300)

    let insets = TileInsets(top: -10, bottom: -20, left: -30, right: -40)
    let frame = WindowGeometry.tiledFrame(visibleFrame: visible, insets: insets)

    #expect(frame == visible)
}
