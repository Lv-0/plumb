import ApplicationServices
import CoreGraphics
import Foundation

/// 基于高频定时器的窗口动画驱动器。
///
/// macOS 上无法用 `NSAnimationContext` 动画化其他 App 的窗口，故通过在主线程上以高频率
/// 反复写入 `AXPosition`/`AXSize` 来插值出丝滑动画。使用 easeInOut 三次曲线插值，
/// 并在动画中读取窗口实际位置：若窗口被用户拖动（与上次写入位置偏离过大）则中止动画。
enum WindowAnimator {
    /// 动画默认时长（秒）。足够短以避免打断，又足够长以呈现丝滑感。
    static let defaultDuration: TimeInterval = 0.28
    /// 定时器频率（Hz）。
    static let tickHz: Int = 120
    /// 判定窗口"被用户挪走"的像素阈值。
    static let jumpAbortThreshold: CGFloat = 40
    /// 连续多少个 tick 读回位置都偏离写入位置超过阈值，才认定为"用户拖动"。
    /// macOS 在 app 刚激活时会短暂地自行移动/弹动窗口（激活动画、聚焦调整），这会
    /// 产生瞬时的大 Δ；若仅凭单帧就中止，会把"系统弹动"误判为"用户拖动"，导致自动
    /// 居中刚启动就被掐断、窗口永远到不了中心（需求："切换到 Music 后 Music 不居中"的根因）。
    /// 真正的用户拖动会持续整个动画过程，因此要求"连续多帧"才中止既不误伤系统弹动，
    /// 又仍能在真实拖动时及时让出控制权。
    static let jumpAbortConsecutiveTicks: Int = 4

    // MARK: - 纯数学（便于单元测试）

    /// easeInOut 三次曲线：t∈[0,1]。
    static func easeInOut(_ t: CGFloat) -> CGFloat {
        let clamped = Swift.max(0, Swift.min(1, t))
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// 阻尼弹簧近似（用于手动“立即居中”的更顺滑手感；自动触发仍用 easeInOut）。
    /// 临界阻尼弹簧 1 - (1 + ωt)e^(-ωt) 归一化到 t=1 时恰好为 1，
    /// 单调、过冲很小，t∈[0,1] → [0,1]。
    static func spring(_ t: CGFloat) -> CGFloat {
        let clamped = Swift.max(0, Swift.min(1, t))
        let omega: Double = 4
        let raw: (Double) -> Double = { tt in 1 - (1 + omega * tt) * exp(-omega * tt) }
        let denom = raw(1)
        guard denom > 1e-6 else { return CGFloat(clamped) }
        return CGFloat(raw(Double(clamped)) / denom)
    }

    /// 给定进度 t，计算插值后的 rect。
    static func interpolatedRect(from start: CGRect, to end: CGRect, t: CGFloat) -> CGRect {
        let p = easeInOut(t)
        let lerp: (CGFloat, CGFloat) -> CGFloat = { a, b in a + (b - a) * p }
        return CGRect(
            x: lerp(start.minX, end.minX),
            y: lerp(start.minY, end.minY),
            width: lerp(start.width, end.width),
            height: lerp(start.height, end.height)
        )
    }

    /// 采样点数量（用于测试估算帧数）。
    static func sampleCount(duration: TimeInterval = defaultDuration) -> Int {
        let n = Int((duration * TimeInterval(tickHz)).rounded())
        return Swift.max(2, n)
    }

    // MARK: - 动画驱动

    /// 帧回调：由调用方决定每一帧的目标 rect（已四舍五入），并实际写入 AX。
    /// 返回 false 表示写入失败或窗口不可动，应中止动画。
    typealias FrameWriter = (_ frame: CGRect) -> Bool
    /// 每帧读取窗口当前 AX 坐标（用于检测用户拖动）。返回 nil 表示读不到。
    typealias CurrentReader = () -> CGRect?
    /// 动画结束回调。
    typealias Completion = () -> Void

    /// 驱动一段从 startFrame 到 endFrame 的动画。
    ///
    /// - `writer`: 将给定 rect 写入窗口（origin+size），返回是否成功。
    /// - `reader`: 读取窗口当前真实 rect；若与上次写入位置偏离超过阈值则中止。
    /// - `completion`: 动画正常结束或被外部取消时都会调用（主线程）。
    ///
    /// 返回底层 `DispatchSourceTimer`，调用方可持有并在切换 app 等场景下 `cancel()` 以立即
    /// 中止动画（窗口停在最后一帧已写入的位置，不回弹、不再写）。返回 nil 表示因 duration<=0
    /// 未启动定时器（已同步写完最终帧）。
    @discardableResult
    static func animate(
        from startFrame: CGRect,
        to endFrame: CGRect,
        duration: TimeInterval = defaultDuration,
        easing: @escaping (_ t: CGFloat) -> CGFloat = easeInOut,
        writer: @escaping FrameWriter,
        reader: @escaping CurrentReader,
        completion: Completion? = nil
    ) -> DispatchSourceTimer? {
        guard duration > 0 else {
            _ = writer(endFrame)
            completion?()
            return nil
        }

        let intervalNanos: Int = 1_000_000_000 / tickHz
        let tickCount = sampleCount(duration: duration)
        let stepDuration = duration / TimeInterval(tickCount)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(intervalNanos))

        // Boxed mutable state（闭包内可变）。
        var index = 0
        var lastWritten: CGRect? = startFrame
        var finished = false
        // 连续偏离计数：只有连续多帧读回位置都偏离写入位置超过阈值，才中止。
        // 初始为 0；每帧若偏离大则 +1，否则归 0；达到 jumpAbortConsecutiveTicks 才中止。
        // 关键：初始几帧不参与判定（启动宽限），避免把"系统激活动画把窗口从起始位置弹开"
        // 误判为用户拖动。前若干帧只写不判，等我们自己写入的位置稳定后再开始监控漂移。
        var consecutiveDrift = 0

        timer.setEventHandler {
            // 完成态：写最终帧并停止。
            if index >= tickCount {
                if !finished {
                    finished = true
                    _ = writer(endFrame)
                    lastWritten = endFrame
                    timer.cancel()
                    completion?()
                }
                return
            }

            // 计时（基于已推进的步数）以保持稳定步进，不受调度抖动影响。
            let progress = CGFloat(index) / CGFloat(tickCount)
            index += 1

            let p = easing(progress)
            let frame = CGRect(
                x: (startFrame.minX + (endFrame.minX - startFrame.minX) * p).rounded(),
                y: (startFrame.minY + (endFrame.minY - startFrame.minY) * p).rounded(),
                width: (startFrame.width + (endFrame.width - startFrame.width) * p).rounded(),
                height: (startFrame.height + (endFrame.height - startFrame.height) * p).rounded()
            )

            // 检测用户是否在动画过程中拖动了窗口。
            // 仅在我们已经写入过至少一帧之后才监控（index > 1 表示已写过 frame[0]），
            // 且要求连续 jumpAbortConsecutiveTicks 帧都偏离——过滤掉 macOS 激活动画造成的
            // 瞬时弹动（单帧大 Δ 不再误判中止，见 jumpAbortConsecutiveTicks 注释）。
            if index > 1, let lastWritten, let current = reader() {
                let dx = abs(current.midX - lastWritten.midX)
                let dy = abs(current.midY - lastWritten.midY)
                if dx > jumpAbortThreshold || dy > jumpAbortThreshold {
                    consecutiveDrift += 1
                    if consecutiveDrift >= jumpAbortConsecutiveTicks {
                        if !finished {
                            finished = true
                            timer.cancel()
                            DiagnosticLog.debug("animator: aborted (user moved window sustained dx=\(dx) dy=\(dy) ticks=\(consecutiveDrift))")
                            completion?()
                        }
                        return
                    }
                } else {
                    consecutiveDrift = 0
                }
            }

            if writer(frame) {
                lastWritten = frame
            }

            _ = stepDuration // 仅保留语义，未使用以避免抖动修正。
        }

        timer.resume()
        return timer
    }

    /// 分帧驱动：每个进度步调用一次 `frameForProgress` 计算目标 rect 再写入。
    /// 适用于 Phase B 这类"每帧重新居中"的场景。
    ///
    /// 返回底层 `DispatchSourceTimer`，调用方可持有并在切换 app 等场景下 `cancel()` 以立即
    /// 中止动画（窗口停在最后一帧已写入的位置，不回弹、不再写）。返回 nil 表示因 duration<=0
    /// 未启动定时器（已同步写完最终帧）。
    @discardableResult
    static func animateCustom(
        duration: TimeInterval = defaultDuration,
        frameForProgress: @escaping (CGFloat) -> CGRect,
        writer: @escaping FrameWriter,
        reader: @escaping CurrentReader,
        completion: Completion? = nil
    ) -> DispatchSourceTimer? {
        guard duration > 0 else {
            _ = writer(frameForProgress(1).rounded())
            completion?()
            return nil
        }

        let intervalNanos: Int = 1_000_000_000 / tickHz
        let tickCount = sampleCount(duration: duration)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(intervalNanos))

        var index = 0
        var lastWritten: CGRect? = nil
        var finished = false

        timer.setEventHandler {
            if index >= tickCount {
                if !finished {
                    finished = true
                    _ = writer(frameForProgress(1).rounded())
                    timer.cancel()
                    completion?()
                }
                return
            }

            let progress = CGFloat(index) / CGFloat(tickCount)
            index += 1

            let frame = frameForProgress(easeInOut(progress)).rounded()

            if !writer(frame) {
                if !finished {
                    finished = true
                    timer.cancel()
                    DiagnosticLog.debug("animator-custom: aborted (writer failed)")
                    completion?()
                }
                return
            }
            lastWritten = frame
        }

        timer.resume()
        return timer
    }
}

private extension CGRect {
    /// 对四舍五入安全的取整（AX 写入整数像素更稳）。
    func rounded() -> CGRect {
        CGRect(
            x: origin.x.rounded(),
            y: origin.y.rounded(),
            width: width.rounded(),
            height: height.rounded()
        )
    }
}
