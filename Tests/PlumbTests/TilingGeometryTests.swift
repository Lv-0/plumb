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

@Test
func topLeftAnchoredOriginKeepsTopLeftEdges() async throws {
    // 目标平铺 frame：左 16 / 下 40 / 右 24 / 上 8（沿用 asymmetric 测试同款 visibleFrame/insets）。
    // maxX = 16 + 960 = 976；maxY = 40 + 752 = 792。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    // App 把高度 snap 小了 20px（如终端按字符行网格、Pages 尺寸受限）。
    let actual = CGSize(width: 960, height: 732)

    let origin = WindowGeometry.topLeftAnchoredOrigin(targetFrame: target, actualSize: actual)

    // 左边距不变（贴 targetFrame.minX）。
    #expect(origin.x == 16)
    // 底部 origin 抬高以保持顶部对齐：40 + (752 - 732) = 60 → 底部边距从 40 放宽到 60。
    #expect(origin.y == 60)
    // 等价断言：maxY(origin, actual) == target.maxY（顶部仍贴 792）。
    let top = origin.y + actual.height
    #expect(top == target.maxY)
}

@Test
func topLeftAnchoredOriginIdentityWhenSizesMatch() async throws {
    // 尺寸完全等于目标时，锚定 origin 即目标 origin（无漂移）。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    let origin = WindowGeometry.topLeftAnchoredOrigin(targetFrame: target, actualSize: target.size)
    #expect(origin == target.origin)
}

@Test
func constrainedTileFallbackOrigin_shorterWindowKeepsTopEdge() async throws {
    // App 高度被 snap 小时，仍保顶部，底部间距变大。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    let actual = CGSize(width: 960, height: 732)

    let origin = WindowGeometry.constrainedTileFallbackOrigin(targetFrame: target, actualSize: actual)

    #expect(origin.x == target.minX)
    #expect(origin.y + actual.height == target.maxY)
}

@Test
func constrainedTileFallbackOrigin_tallerWindowKeepsBottomEdge() async throws {
    // Numbers 外接屏：实际高度可能比目标高，必须保底部间距，不能把多出的高度压到底部。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let actual = CGSize(width: 1888, height: 1050)

    let origin = WindowGeometry.constrainedTileFallbackOrigin(targetFrame: target, actualSize: actual)

    #expect(origin.x == target.minX)
    #expect(origin.y == target.minY)
    #expect(origin.y + actual.height == target.maxY + 20)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - frameMatchesTiledTarget（平铺完成严格判定：origin 严格 / size 宽松）
//
// 背景：首次平铺的完成确认（didWindowActuallyTile / isWindowNearTiledTarget）此前用
// 四维统一 16px 容差。iWork（Numbers/Pages）在 smooth Phase B resize 后会让 origin 漂移
//（实测 x: 16→25，漂移 9px < 16px），被宽松判定误判为「已完成平铺」→ markCentered +
// processedPIDs 锁死本激活周期 → 首次平铺右侧边距偏差；切 App 会清锁重平铺故正常。
// 修复：完成判定改用「origin 严格 3px、size 宽松 16px」——origin 严格挡下 iWork 漂移，
// size 宽松保留对 Terminal/electerm 按字符网格 snap 尺寸（偏差可达 10-20px）的 app 的兼容。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func frameMatchesTiledTarget_originDrift9px_rejects() async throws {
    // ⭐ Numbers 根因回归保护：target origin x=16，实际 origin x=25（漂移 9px），size 精确。
    // 旧的四维统一 16px 容差会判定通过（误锁在漂移位置）；严格 origin 容差 3px 必须挡下。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    let drifted = CGRect(x: 25, y: 40, width: 960, height: 752)
    #expect(WindowGeometry.frameMatchesTiledTarget(drifted, target: target) == false)
}

@Test
func frameMatchesTiledTarget_exactMatch_accepts() async throws {
    // 四维零偏差 → 通过。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    #expect(WindowGeometry.frameMatchesTiledTarget(target, target: target) == true)
}

@Test
func frameMatchesTiledTarget_within2px_accepts() async throws {
    // origin 各偏 2px（在 3px 严格容差边界内）、size 各偏 2px（远在 16px 宽松容差内）→ 通过。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    let near = CGRect(x: 18, y: 42, width: 962, height: 754)
    #expect(WindowGeometry.frameMatchesTiledTarget(near, target: target) == true)
}

@Test
func frameMatchesTiledTarget_sizeSnapOnly_accepts() async throws {
    // Terminal/electerm 字符网格 snap：origin 精确、width 偏 15px（在 16px size 宽松容差内）→ 通过。
    // 这类 app 尺寸确实无法精确到位，但 origin 正确，应判定为完成并锁 PID（避免每次切 App 重平铺回归）。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    let snapped = CGRect(x: 16, y: 40, width: 945, height: 752)
    #expect(WindowGeometry.frameMatchesTiledTarget(snapped, target: target) == true)
}

@Test
func frameMatchesTiledTarget_sizeSnapBeyondLenient_rejects() async throws {
    // width 偏 20px 超出 16px size 宽松容差 → 拒绝（过大 snap 仍需重试）。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    let tooFar = CGRect(x: 16, y: 40, width: 940, height: 752)
    #expect(WindowGeometry.frameMatchesTiledTarget(tooFar, target: target) == false)
}

@Test
func frameMatchesTiledTarget_originDriftBlocksEvenWithExactSize() async throws {
    // 锁定 iWork 场景：即使 size 完美，origin x 漂 9px 仍必须拒绝（不能被 size 精确掩盖）。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    let drifted = CGRect(x: 25, y: 40, width: 960, height: 752)
    #expect(WindowGeometry.frameMatchesTiledTarget(drifted, target: target) == false)
}

@Test
func frameCoversTiledTarget_outwardOvershootBeyond3px_rejects() async throws {
    // ⭐ 根因 D 回归保护：旧实现允许 top 24px 外扩，会把 Numbers 多出的 20px 高度向顶部
    // 外扩后判定「完成」，吞掉用户设置的 top inset。收紧到 3px 后，20px 顶部外扩必须拒绝。
    // 这种形态改为由 frameMatchesFallbackProduct（妥协形态相等）接受——锚定与判定同源。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let covering = CGRect(x: 16, y: 10, width: 1888, height: 1050)
    #expect(WindowGeometry.frameCoversTiledTarget(covering, target: target) == false)
}

@Test
func frameCoversTiledTarget_bottomOvershoot_rejects() async throws {
    // 完整吞掉用户设置的 10px bottom inset，外接屏上肉眼明显，必须拒绝。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let bottomOvershoot = CGRect(x: 16, y: 0, width: 1888, height: 1050)
    #expect(WindowGeometry.frameCoversTiledTarget(bottomOvershoot, target: target) == false)
}

@Test
func frameCoversTiledTarget_smallBottomOvershoot_rejects() async throws {
    // 5px bottom 外扩超出收紧后的 3px 容差 → 拒绝（不再靠谓词接受）。
    // 这种「系统顶部夹取造成的不可达误差」现由阶段 1 的会话预算兜底接受，而非判定谓词。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let nearlyBottomPreserved = CGRect(x: 16, y: 5, width: 1888, height: 1045)
    #expect(WindowGeometry.frameCoversTiledTarget(nearlyBottomPreserved, target: target) == false)
}

@Test
func frameCoversTiledTarget_leftOvershoot_rejects() async throws {
    // 左侧外扩同样会吞掉用户设置的 left inset；当前 fallback 只允许向右/向顶部外扩。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let leftOvershoot = CGRect(x: 0, y: 10, width: 1904, height: 1030)
    #expect(WindowGeometry.frameCoversTiledTarget(leftOvershoot, target: target) == false)
}

@Test
func frameCoversTiledTarget_inwardGap_rejects() async throws {
    // 右侧少铺 19px 仍是可见空白，不能因“接近目标”而锁定。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let undersized = CGRect(x: 16, y: 10, width: 1869, height: 1030)
    #expect(WindowGeometry.frameCoversTiledTarget(undersized, target: target) == false)
}

@Test
func frameCoversTiledTarget_largeOvershoot_rejects() async throws {
    // 向外超出过多更像错误坐标空间或错窗，不应吞掉。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let wrong = CGRect(x: -200, y: -200, width: 2300, height: 1400)
    #expect(WindowGeometry.frameCoversTiledTarget(wrong, target: target) == false)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - 妥协形态 / 统一完成判定（expectedFallbackFrame + frameMatchesFallbackProduct
//        + frameSatisfiesFinalTiledTarget）
//
// 阶段 2：定义唯一的「妥协形态」纯函数 expectedFallbackFrame（即 constrainedTileFallbackOrigin
// 推出的完整 CGRect）。完成判定改为「落到目标」或「等于妥协形态」或「3px 内完整覆盖」，
// 三者经 frameSatisfiesFinalTiledTarget 短路。锚定（emitFinalAnchor）产出的任何形态判定必然接受
// → 反复平铺循环从构造上消除；其余形态继续重试，由阶段 1 的会话预算兜底。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func expectedFallbackFrame_tallerWindowKeepsBottomInset() async throws {
    // Numbers 外接屏：实际高度 1050 > 目标 1030 → 妥协形态保底部（y=target.minY=10），多出的
    // 20px 向顶部外扩。这正是 emitFinalAnchor 会锚定的 frame，判定必须接受。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let actual = CGSize(width: 1888, height: 1050)

    let product = WindowGeometry.expectedFallbackFrame(targetFrame: target, actualSize: actual)

    #expect(product.minX == target.minX)
    #expect(product.minY == target.minY)                 // 保底部 inset
    #expect(product.height == actual.height)             // 用实际高度
    #expect(product.maxY == target.maxY + 20)            // 多出高度向顶外扩
}

@Test
func expectedFallbackFrame_shorterWindowKeepsTopEdge() async throws {
    // Terminal/electerm 字符网格 snap：实际高度 732 < 目标 752 → 妥协形态保顶部，底部放宽。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    let actual = CGSize(width: 960, height: 732)

    let product = WindowGeometry.expectedFallbackFrame(targetFrame: target, actualSize: actual)

    #expect(product.minX == target.minX)
    #expect(product.maxY == target.maxY)                 // 保顶部
    #expect(product.minY + actual.height == target.maxY)
}

@Test
func frameMatchesFallbackProduct_tallerAnchoredWindow_accepts() async throws {
    // emitFinalAnchor 锚定后的 Numbers 窗口（高 1050、y=10）正好等于妥协形态 → 判定通过。
    // 这条测试是「锚定与判定同源、循环消除」的直接编码。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let anchored = CGRect(x: 16, y: 10, width: 1888, height: 1050)
    #expect(WindowGeometry.frameMatchesFallbackProduct(anchored, target: target) == true)
}

@Test
func frameMatchesFallbackProduct_driftedFromFallback_rejects() async throws {
    // 妥协形态是 y=10；若 origin 漂到 y=20（10px > 3px 容差）→ 不等于妥协形态，拒绝。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let drifted = CGRect(x: 16, y: 20, width: 1888, height: 1050)
    #expect(WindowGeometry.frameMatchesFallbackProduct(drifted, target: target) == false)
}

@Test
func frameMatchesFallbackProduct_narrowWidth_rejects() async throws {
    // Numbers 右侧露白类形态：如果把实际宽度带入 fallback product，短宽窗口会被误判为完成。
    // fallback 只允许高度妥协；宽度必须仍贴近平铺目标，否则右边界会明显短一截。
    let target = CGRect(x: 16, y: 16, width: 1888, height: 1018)
    let narrowTopAnchored = CGRect(x: 16, y: 40, width: 1760, height: 994)
    #expect(WindowGeometry.frameMatchesFallbackProduct(narrowTopAnchored, target: target) == false)
}

@Test
func frameSatisfiesFinalTiledTarget_exactTarget_accepts() async throws {
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    #expect(WindowGeometry.frameSatisfiesFinalTiledTarget(target, target: target) == true)
}

@Test
func frameSatisfiesFinalTiledTarget_fallbackProduct_accepts() async throws {
    // 高窗口保底锚定 → 妥协形态 → 统一判定接受（不再循环）。
    let target = CGRect(x: 16, y: 10, width: 1888, height: 1030)
    let anchored = CGRect(x: 16, y: 10, width: 1888, height: 1050)
    #expect(WindowGeometry.frameSatisfiesFinalTiledTarget(anchored, target: target) == true)
}

@Test
func frameSatisfiesFinalTiledTarget_narrowFallbackProduct_rejects() async throws {
    // 即便高度是保顶妥协，只要宽度明显短于目标，就不能通过统一完成判定。
    let target = CGRect(x: 16, y: 16, width: 1888, height: 1018)
    let narrowTopAnchored = CGRect(x: 16, y: 40, width: 1760, height: 994)
    #expect(WindowGeometry.frameSatisfiesFinalTiledTarget(narrowTopAnchored, target: target) == false)
}

@Test
func frameSatisfiesFinalTiledTarget_originDrift_rejects() async throws {
    // iWork origin 漂移 9px：既非目标、也非妥协形态、也非 3px 覆盖 → 拒绝（继续重试）。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    let drifted = CGRect(x: 25, y: 40, width: 960, height: 752)
    #expect(WindowGeometry.frameSatisfiesFinalTiledTarget(drifted, target: target) == false)
}

@Test
func frameSatisfiesFinalTiledTarget_terminalSnap_accepts() async throws {
    // Terminal origin 精确、width 偏 15px → 落到 frameMatchesTiledTarget（size 宽松）→ 接受。
    let target = CGRect(x: 16, y: 40, width: 960, height: 752)
    let snapped = CGRect(x: 16, y: 40, width: 945, height: 752)
    #expect(WindowGeometry.frameSatisfiesFinalTiledTarget(snapped, target: target) == true)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Phase-B resize policy
//
// 大跨度放大（Pages/Numbers 新文稿、极小 Safari → 平铺目标）应直接走稳健分步路径，
// 避免 60Hz smooth 写 size 让目标 app 的 layout/AX 读回追不上，最终停在偏小尺寸。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func robustPhaseBPolicy_smallWindowToTileTarget_usesRobust() async throws {
    let start = CGSize(width: 520, height: 360)
    let target = CGSize(width: 1408, height: 843)

    #expect(WindowCenteringService.shouldUseRobustPhaseB(startSize: start, endSize: target) == true)
}

@Test
func robustPhaseBPolicy_largeSingleAxisDelta_usesRobust() async throws {
    let start = CGSize(width: 900, height: 820)
    let target = CGSize(width: 1408, height: 843)

    #expect(WindowCenteringService.shouldUseRobustPhaseB(startSize: start, endSize: target) == true)
}

@Test
func robustPhaseBPolicy_nearTarget_keepsSmooth() async throws {
    let start = CGSize(width: 1220, height: 790)
    let target = CGSize(width: 1408, height: 843)

    #expect(WindowCenteringService.shouldUseRobustPhaseB(startSize: start, endSize: target) == false)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Numbers 顶距翻倍 bug 回归保护（逐边语义 + 统一判定）
//
// 真实事故数据：外接屏 1920×1080，visibleFrame=(0,0,1920,1050)，Numbers per-app insets
// top=15.62 / bottom=16.31 / left=16 / right=16。平铺目标 frame = (16, 16, 1888, 1018)。
// 事故链：Numbers 载入忙碌期拒缩放 → 旧贴底收缩阶梯在忙碌期结束时接受了矮 16px 的高度（1002），
// 贴底锚定 → maxY 缺 16px → 旧「minY 严格 + height ≤16」判定放行 → 锁定，顶距 = 15.62 + 16.38 ≈ 32（翻倍）。
// 修复：(1) frameMatchesTiledTarget 改逐边语义，顶边 ±6px 挡住「贴底短高」；
//       (2) 删除收缩阶梯，改精确目标重写链；(3) forceLock 前的位置修正兜底。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func frameMatchesTiledTarget_bottomAnchoredShort16_rejects() async throws {
    // ⭐ 顶距翻倍 bug 核心回归：日志中被错误验收的形态。贴底（minY=16=target.minY）但高度矮 16px
    //（1002 vs 1018）→ maxY 缺 16px。旧「minY 严格 + height ≤16 宽松」放行；逐边语义顶边 ±6px 必须挡下。
    let target = CGRect(x: 16, y: 16, width: 1888, height: 1018)
    let bottomAnchoredShort = CGRect(x: 16, y: 16, width: 1888, height: 1002)
    #expect(WindowGeometry.frameMatchesTiledTarget(bottomAnchoredShort, target: target) == false)
}

@Test
func frameSatisfiesFinalTiledTarget_bottomAnchoredShort16_rejects() async throws {
    // ⭐ 统一判定也必须拒绝：fallbackProduct 的矮窗产物是保顶 (16, 32, 1888, 1002)，不匹配贴底；
    // covers 要求完整覆盖、四向 ≤3px，贴底短高既露顶白也不匹配。三条短路全不通过。
    let target = CGRect(x: 16, y: 16, width: 1888, height: 1018)
    let bottomAnchoredShort = CGRect(x: 16, y: 16, width: 1888, height: 1002)
    #expect(WindowGeometry.frameSatisfiesFinalTiledTarget(bottomAnchoredShort, target: target) == false)
}

@Test
func frameMatchesTiledTarget_topAnchoredShort16_accepts() async throws {
    // 保顶妥协（Terminal/electerm 字符网格 snap / 新版 emitFinalAnchor 锚定产物）：
    // 顶部贴 target.maxY（maxY=1034 无缺口），底部放宽 16px（minY=32，底距变宽但顶距正确）。
    // 逐边语义：底边向内收 +16 ∈ [−3,+16] 边界通过，顶边 0 通过 → 接受。
    let target = CGRect(x: 16, y: 16, width: 1888, height: 1018)
    let topAnchoredShort = CGRect(x: 16, y: 32, width: 1888, height: 1002)
    #expect(WindowGeometry.frameMatchesTiledTarget(topAnchoredShort, target: target) == true)
}

@Test
func frameSatisfiesFinalTiledTarget_topAnchoredShort24_acceptsViaFallbackProduct() async throws {
    // 缺口 24px 超出逐边宽松（底边向内收 +24 > 16），但等于保顶妥协产物
    //（actualSize.height=994 < 1018 → keep top → y = target.maxY − 994 = 40）→ fallbackProduct 接受。
    // 这正是 anchorWindowToFallbackOrigin / 精确重写链会锚定的形态，判定必然接受。
    let target = CGRect(x: 16, y: 16, width: 1888, height: 1018)
    let topAnchoredShort24 = CGRect(x: 16, y: 40, width: 1888, height: 994)
    #expect(WindowGeometry.frameSatisfiesFinalTiledTarget(topAnchoredShort24, target: target) == true)
}

@Test
func frameSatisfiesFinalTiledTarget_bottomAnchoredShort24_rejects() async throws {
    // 贴底 + 矮 24px：顶边缺口 24px、底边 0；既非逐边通过（顶 −24 < −6），也非保顶妥协（保顶应 maxY=1034，
    // 此处 maxY=1010），covers 也露顶白。三条短路全拒——防止更大的贴底短高形态被锁定。
    let target = CGRect(x: 16, y: 16, width: 1888, height: 1018)
    let bottomAnchoredShort24 = CGRect(x: 16, y: 16, width: 1888, height: 994)
    #expect(WindowGeometry.frameSatisfiesFinalTiledTarget(bottomAnchoredShort24, target: target) == false)
}

@Test
func frameSatisfiesFinalTiledTarget_offscreenBottom_rejects() async throws {
    // 日志中旧阶梯被拒格子的出屏中间态：贴底但用「假设高度」换算把实际 1050 高窗口的底边
    // 推到屏幕外（minY=−16）。底边 −16−16=−32 远超 [−3,+16]，必须拒绝——这正是位置写入必须用
    // 实际尺寸换算（而非假设高度）的回归保护。
    let target = CGRect(x: 16, y: 16, width: 1888, height: 1018)
    let offscreenBottom = CGRect(x: 16, y: -16, width: 1888, height: 1050)
    #expect(WindowGeometry.frameSatisfiesFinalTiledTarget(offscreenBottom, target: target) == false)
}
