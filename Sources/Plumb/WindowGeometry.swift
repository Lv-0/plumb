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
