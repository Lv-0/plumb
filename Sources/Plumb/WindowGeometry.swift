import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WindowGeometry
//
// 模块角色：纯几何计算（无 AppKit 依赖，完全可单测）。
//
// 职责：把"居中 / 约束 / 平铺 / 可用区 inset"这些数学下沉为纯函数：
//   - centeredOrigin   ：在 visibleFrame 内居中（含 best-effort 夹取，不溢出）。
//   - constrainedOrigin：把任意原点约束进 bounds（用于把远离屏幕的窗口先拉回可视区）。
//   - tiledFrame       ：visibleFrame 内缩四向 insets 得到平铺目标（带防负/防塌缩保护）。
//   - insetsFromVisibleFrame：从 frame 与 visibleFrame 反推逐边 inset（让 Dock 在
//     左/右/下、菜单栏在顶的逐屏差异可独立测试）。
//
// 不变量：所有返回坐标都四舍五入到整数像素（与 AX 写入一致，便于测试断言）。
// ─────────────────────────────────────────────────────────────────────────────

enum WindowGeometry {
    static func centeredOrigin(windowSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        // Center relative to the usable region (visibleFrame). If the window is larger than the visible area on
        // an axis, we keep the centered origin (best-effort) instead of clamping to an edge.
        let centeredX = visibleFrame.midX - windowSize.width / 2.0
        let centeredY = visibleFrame.midY - windowSize.height / 2.0

        var x = centeredX
        var y = centeredY

        if windowSize.width <= visibleFrame.width {
            let minX = visibleFrame.minX
            let maxX = visibleFrame.maxX - windowSize.width
            x = clamp(centeredX, min: minX, max: max(minX, maxX))
        }

        if windowSize.height <= visibleFrame.height {
            let minY = visibleFrame.minY
            let maxY = visibleFrame.maxY - windowSize.height
            y = clamp(centeredY, min: minY, max: max(minY, maxY))
        }

        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    static func constrainedOrigin(origin: CGPoint, windowSize: CGSize, bounds: CGRect) -> CGPoint {
        let minX = bounds.minX
        let maxX = bounds.maxX - windowSize.width
        let minY = bounds.minY
        let maxY = bounds.maxY - windowSize.height

        let lowerX = Swift.min(minX, maxX)
        let upperX = Swift.max(minX, maxX)
        let lowerY = Swift.min(minY, maxY)
        let upperY = Swift.max(minY, maxY)

        let constrainedX = clamp(origin.x, min: lowerX, max: upperX)
        let constrainedY = clamp(origin.y, min: lowerY, max: upperY)

        return CGPoint(x: constrainedX.rounded(), y: constrainedY.rounded())
    }

    /// visibleFrame 内缩四向 insets 得到平铺目标（带防负/防塌缩保护）。
    ///
    /// - 逐侧 clamp 到非负，并限制单侧不超过 `(dim-1)/2`，保证同轴两侧之和 ≤ dim-1，
    ///   永不把帧塌缩到 <1px。
    /// - visibleFrame 为左下原点坐标系（NSScreen 约定）：`bottom` 加到 minY，`top` 从高度里扣。
    /// - 结果四舍五入到整像素（与 AX 写入一致，便于测试断言）。
    static func tiledFrame(visibleFrame: CGRect, insets: TileInsets) -> CGRect {
        let maxInsetX = max(0, (visibleFrame.width - 1) / 2)
        let maxInsetY = max(0, (visibleFrame.height - 1) / 2)

        let left = min(max(0, insets.left), maxInsetX)
        let right = min(max(0, insets.right), maxInsetX)
        let top = min(max(0, insets.top), maxInsetY)
        let bottom = min(max(0, insets.bottom), maxInsetY)

        let x = visibleFrame.minX + left
        let y = visibleFrame.minY + bottom
        let width = max(1, visibleFrame.width - left - right)
        let height = max(1, visibleFrame.height - top - bottom)

        return CGRect(
            x: x.rounded(),
            y: y.rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }

    /// 平铺目标的左上角锚定 fallback：当 app 把窗口尺寸 snap 到非目标尺寸时，
    /// 保持目标左/上边距不变，按实际尺寸重算右/下边距（而非重新居中）。
    ///
    /// 用于 `finalizePhaseB`：终端类 app（如 electerm 按字符行网格 snap 高度）或 Pages
    /// 这类对窗口尺寸有限制的文档 app，可能拒绝缩放到目标尺寸。此时若用 `centeredOrigin`
    /// 重新居中，会破坏平铺要求的左上角锚定和四向 insets，导致窗口整体漂移。本 helper
    /// 改为以 `targetFrame` 的左上角为锚点：左/上边距严格等于目标 insets，右/下边距随实际
    /// 尺寸放宽（顶部贴 `targetFrame.maxY`，左贴 `targetFrame.minX`）。
    ///
    /// 返回 bottom-left 原点坐标系下的 origin（与 `tiledFrame` / `centeredOrigin` 一致），
    /// 四舍五入到整像素（与 AX 写入一致）。
    static func topLeftAnchoredOrigin(targetFrame: CGRect, actualSize: CGSize) -> CGPoint {
        CGPoint(
            x: targetFrame.minX,
            y: targetFrame.maxY - actualSize.height   // 顶部对齐 targetFrame.maxY，底部由 actualSize 决定
        )
    }

    /// 平铺尺寸受 app 限制时的最终锚定 fallback。
    ///
    /// 宽度仍保持左边距；高度分两类：
    /// - 实际高度比目标矮：保顶部，底部间距放宽（Terminal/electerm 字符网格 snap）。
    /// - 实际高度比目标高：保底部，顶部少量外扩（Numbers 外接屏会把高度读回 visibleFrame 高度）。
    static func constrainedTileFallbackOrigin(targetFrame: CGRect, actualSize: CGSize) -> CGPoint {
        let y = actualSize.height > targetFrame.height
            ? targetFrame.minY
            : targetFrame.maxY - actualSize.height
        return CGPoint(x: targetFrame.minX, y: y.rounded())
    }

    /// 「妥协形态」：app 拒绝目标尺寸时，Plumb 愿意留下的最终 frame。
    ///
    /// 即 `constrainedTileFallbackOrigin` 推出的完整 CGRect（宽度保左距；高度矮→保顶、高→保底）。
    /// 这是**唯一的**妥协形态纯函数：`emitFinalAnchor` 锚定时用它推出 origin，完成判定用它推出
    /// 应被接受的完整 frame。由此「锚定愿意留下的任何形态，判定必然接受」——循环从构造上消除
    ///（根因 D：Numbers 把高度读回 visibleFrame 后，旧 `frameCoversTiledTarget` 的 24px 外扩容差
    /// 既会接受、也会拒绝同一形态，造成反复重铺）。
    static func expectedFallbackFrame(targetFrame: CGRect, actualSize: CGSize) -> CGRect {
        CGRect(origin: constrainedTileFallbackOrigin(targetFrame: targetFrame, actualSize: actualSize), size: actualSize)
    }

    /// 判断 frame 是否正好等于「妥协形态」（origin 由 `expectedFallbackFrame` 决定，size 用实际值）。
    /// 四维统一容差（默认 3px）：origin 与 size 都必须紧贴妥协形态。这是「app 真硬限、已保底锚定」
    /// 的唯一可接受宽松条件——既不像 `frameMatchesTiledTarget` 那样要求 size≈target（妥协形态 size ≠ target），
    /// 也不像旧 `frameCoversTiledTarget` 那样允许 24px 外扩（会吞掉用户设置的 inset）。
    static func frameMatchesFallbackProduct(
        _ frame: CGRect,
        target: CGRect,
        tolerance: CGFloat = 3
    ) -> Bool {
        let product = expectedFallbackFrame(targetFrame: target, actualSize: frame.size)
        return abs(frame.minX - product.minX) <= tolerance &&
            abs(frame.minY - product.minY) <= tolerance &&
            abs(frame.width - product.width) <= tolerance &&
            abs(frame.height - product.height) <= tolerance
    }

    /// 平铺完成严格判定：frame 四维是否「origin 严格、size 宽松」地匹配平铺目标。
    ///
    /// 用途：区分「真正落到平铺目标」与「尺寸到位但 origin 漂移」——后者会被宽松判定
    ///（四维统一容差）误判为已完成，导致 markCentered + processedPIDs 锁在漂移位置上，
    /// 表现为 iWork/Numbers 首次平铺后右侧边距偏差（实测 origin x 漂移 9px）。
    ///
    /// 容差策略：**origin 严格（originTolerance，默认 3px）、size 宽松（sizeTolerance，默认 16px）**。
    ///   - origin 严格挡住 iWork smooth Phase B resize 后的 origin 漂移（< 16px 但肉眼可见、改变边距）；
    ///   - size 宽松保留对 Terminal/electerm 按字符网格 snap 尺寸的 app 的兼容——它们的尺寸
    ///     确实无法精确到位（width/height 偏差可达 10-20px），但 origin 正确，应判定为完成并锁 PID，
    ///     避免首次启动反复重试到上限 + 每次切 App 回来都重新平铺的回归。
    static func frameMatchesTiledTarget(
        _ frame: CGRect,
        target: CGRect,
        originTolerance: CGFloat = 3,
        sizeTolerance: CGFloat = 16
    ) -> Bool {
        abs(frame.minX - target.minX) <= originTolerance &&
            abs(frame.minY - target.minY) <= originTolerance &&
            abs(frame.width - target.width) <= sizeTolerance &&
            abs(frame.height - target.height) <= sizeTolerance
    }

    /// 平铺完成兜底判定：窗口没有向内露出空白，并且只少量外扩。
    ///
    /// Numbers 可能拒绝目标高度、读回更高窗口。最终锚定会优先保底部间距，让多出的高度
    /// 向顶部外扩；这种不是「未铺满」，继续重试只会循环。若 app 的最小高度仍略高于
    /// 可用高度减 bottom inset，macOS 会把顶部夹到可见区顶端，底部最多会少几像素；
    /// 这种不可达目标接受，小于等于容差。完整吞掉 bottom inset 的贴底状态仍拒绝。
    ///
    /// ⚠️ 外扩容差收紧到 3px（与内露白同阈）。旧实现 top 24px / bottom 6px 的外扩容差
    /// 大于典型 insets，是「锁死在肉眼可见错误间距」的合法化通道——用户设置的 inset 常常
    /// 只有 10-16px，24px 外扩会直接吞掉它。3px 是「坐标空间探测噪声 / 系统顶部夹取」的
    /// 合理上界，超过 3px 的外扩必须走 `frameMatchesFallbackProduct`（妥协形态相等）而非本方法。
    static func frameCoversTiledTarget(
        _ frame: CGRect,
        target: CGRect,
        inwardGapTolerance: CGFloat = 3,
        outwardOvershootTolerance: CGFloat = 3,
        bottomOvershootTolerance: CGFloat = 3
    ) -> Bool {
        let leftInwardGap = frame.minX - target.minX
        let rightInwardGap = target.maxX - frame.maxX
        let bottomInwardGap = frame.minY - target.minY
        let topInwardGap = target.maxY - frame.maxY

        let leftOvershoot = target.minX - frame.minX
        let rightOvershoot = frame.maxX - target.maxX
        let bottomOvershoot = target.minY - frame.minY
        let topOvershoot = frame.maxY - target.maxY

        return leftInwardGap <= inwardGapTolerance &&
            rightInwardGap <= inwardGapTolerance &&
            bottomInwardGap <= inwardGapTolerance &&
            topInwardGap <= inwardGapTolerance &&
            leftOvershoot <= inwardGapTolerance &&
            rightOvershoot <= outwardOvershootTolerance &&
            bottomOvershoot <= bottomOvershootTolerance &&
            topOvershoot <= outwardOvershootTolerance
    }

    /// 统一平铺完成判定（唯一真源）：一个 frame 是否应被接受为「平铺完成」。
    ///
    /// 三选一，按此顺序短路：
    ///   1. `frameMatchesTiledTarget` —— 真正落到平铺目标（origin 严格 3px / size 宽松 16px）。
    ///   2. `frameMatchesFallbackProduct` —— 等于「妥协形态」（四维 3px）。这是 app 拒绝目标尺寸后
    ///      `emitFinalAnchor` 愿意留下的唯一妥协 frame；判定必然接受 → 锚定与判定同源，循环消除。
    ///   3. `frameCoversTiledTarget` —— 完整覆盖目标、四向外扩 ≤ 3px 的几何兜底（应对系统顶部夹取
    ///      产生的 ±3px 不可达误差，不再吞 inset）。
    ///
    /// 抽成 nonisolated 纯函数，供 `emitFinalAnchor` / `tileReachedTarget` / `isWindowAtTiledTarget`
    ///（经服务层薄封装）共用，并直接单元测试。
    static func frameSatisfiesFinalTiledTarget(_ frame: CGRect, target: CGRect) -> Bool {
        if frameMatchesTiledTarget(frame, target: target) { return true }
        if frameMatchesFallbackProduct(frame, target: target) { return true }
        if frameCoversTiledTarget(frame, target: target) { return true }
        return false
    }

    /// 把“全屏 frame 与可用 visibleFrame”之间的逐边 inset 计算下沉为纯函数。
    /// 让 Dock 在左/右/下、菜单栏在顶部的逐屏差异可被独立测试。
    static func insetsFromVisibleFrame(frame: CGRect, visible: CGRect) -> ScreenSelection.EdgeInsets {
        ScreenSelection.EdgeInsets(
            left: visible.minX - frame.minX,
            right: frame.maxX - visible.maxX,
            top: frame.maxY - visible.maxY,
            bottom: visible.minY - frame.minY
        )
    }

    private static func clamp(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        Swift.max(lowerBound, Swift.min(value, upperBound))
    }
}
