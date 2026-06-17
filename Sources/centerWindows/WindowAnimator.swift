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
    /// - `completion`: 动画正常结束或中止时都会调用（主线程）。
    static func animate(
        from startFrame: CGRect,
        to endFrame: CGRect,
        duration: TimeInterval = defaultDuration,
        easing: @escaping (_ t: CGFloat) -> CGFloat = easeInOut,
        writer: @escaping FrameWriter,
        reader: @escaping CurrentReader,
        completion: Completion? = nil
    ) {
        guard duration > 0 else {
            _ = writer(endFrame)
            completion?()
            return
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
            if let lastWritten, let current = reader() {
                let dx = abs(current.midX - lastWritten.midX)
                let dy = abs(current.midY - lastWritten.midY)
                if dx > jumpAbortThreshold || dy > jumpAbortThreshold {
                    if !finished {
                        finished = true
                        timer.cancel()
                        DiagnosticLog.debug("animator: aborted (user moved window dx=\(dx) dy=\(dy))")
                        completion?()
                    }
                    return
                }
            }

            if writer(frame) {
                lastWritten = frame
            }

            _ = stepDuration // 仅保留语义，未使用以避免抖动修正。
        }

        timer.resume()
    }

    /// 分帧驱动：每个进度步调用一次 `frameForProgress` 计算目标 rect 再写入。
    /// 适用于 Phase B 这类"每帧重新居中"的场景。
    static func animateCustom(
        duration: TimeInterval = defaultDuration,
        frameForProgress: @escaping (CGFloat) -> CGRect,
        writer: @escaping FrameWriter,
        reader: @escaping CurrentReader,
        completion: Completion? = nil
    ) {
        guard duration > 0 else {
            _ = writer(frameForProgress(1).rounded())
            completion?()
            return
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

            // Phase B（每帧重新居中 + 改尺寸）会"主动"改变 origin 和 size，
            // 因此无法可靠地用 reader() 区分"用户干预"与"我们自己的写入"——
            // 许多 App 在被 set kAXSize 后会以约束/弹性回弹，读回的 size 与写入值有几
            // 十像素差异，若据此中止会让平铺放大动画瞬间夭折。
            // 这里仅在 writer 写入失败时中止（窗口不可动），不再因读回差异中止。
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
