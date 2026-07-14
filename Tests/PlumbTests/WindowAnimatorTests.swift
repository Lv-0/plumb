import CoreGraphics
import Foundation
import Testing
@testable import Plumb

@Test
func easeInOutEndpoints() async throws {
    // 曲线两端必须正好为 0 和 1。
    #expect(WindowAnimator.easeInOut(0) == 0)
    #expect(WindowAnimator.easeInOut(1) == 1)
}

@Test
func easeInOutMonotonicAndMidpoint() async throws {
    // easeInOut 三次曲线在 0.5 处应等于 0.5，且单调递增。
    #expect(WindowAnimator.easeInOut(0.5) == 0.5)
    var prev: CGFloat = -1
    for i in 0...20 {
        let t = CGFloat(i) / 20.0
        let v = WindowAnimator.easeInOut(t)
        #expect(v >= prev)
        #expect(v >= 0 && v <= 1)
        prev = v
    }
}

@Test
func easeInOutClampsOutOfRange() async throws {
    #expect(WindowAnimator.easeInOut(-1) == 0)
    #expect(WindowAnimator.easeInOut(2) == 1)
}

@Test
func easeOutEndpoints() async throws {
    // 曲线两端必须正好为 0 和 1。
    #expect(WindowAnimator.easeOut(0) == 0)
    #expect(WindowAnimator.easeOut(1) == 1)
}

@Test
func easeOutMonotonicAndMidpoint() async throws {
    // 二次 ease-out：1 - (1-t)^2，t=0.5 时为 0.75，单调递增，值域 [0,1]。
    #expect(WindowAnimator.easeOut(0.5) == 0.75)
    var prev: CGFloat = -1
    for i in 0...20 {
        let t = CGFloat(i) / 20.0
        let v = WindowAnimator.easeOut(t)
        #expect(v >= prev)
        #expect(v >= 0 && v <= 1)
        prev = v
    }
}

@Test
func easeOutClampsOutOfRange() async throws {
    #expect(WindowAnimator.easeOut(-1) == 0)
    #expect(WindowAnimator.easeOut(2) == 1)
}

@Test
func interpolatedRectMatchesEasing() async throws {
    let start = CGRect(x: 0, y: 0, width: 100, height: 100)
    let end = CGRect(x: 200, y: 400, width: 300, height: 500)

    let mid = WindowAnimator.interpolatedRect(from: start, to: end, t: 0.5)
    // 在 t=0.5 处 easeInOut=0.5，故为两端中点。
    #expect(mid.origin.x == 100)
    #expect(mid.origin.y == 200)
    #expect(mid.width == 200)
    #expect(mid.height == 300)

    let zero = WindowAnimator.interpolatedRect(from: start, to: end, t: 0)
    #expect(zero == start)

    let one = WindowAnimator.interpolatedRect(from: start, to: end, t: 1)
    #expect(one == end)
}

@Test
func sampleCountReasonable() async throws {
    let n = WindowAnimator.sampleCount()
    // 默认 0.18s @ 120Hz ≈ 21.6 => 22 帧，且不少于 2。
    #expect(n >= 2)
    #expect(n <= 200)
}

@Test
func interpolatedRectKeepsCenterConstant() async throws {
    // 验证"从中心对称扩大"的关键不变量：当窗口相对同一 visibleFrame 居中时，
    // 无论尺寸如何变化，窗口的中心点（midX/midY）恒等于 visibleFrame 的中心。
    // （注：centeredOrigin 返回的是左下角原点，会随尺寸变化；保持恒定的是窗口中心。）
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let centerX = visible.midX
    let centerY = visible.midY

    let startSize = CGSize(width: 600, height: 400)
    let endSize = CGSize(width: 1200, height: 800)

    // 在 Phase B 中，每一帧用当前尺寸重新居中，窗口中心应始终恒定。
    for i in 0...10 {
        let p = WindowAnimator.easeInOut(CGFloat(i) / 10.0)
        let curW = startSize.width + (endSize.width - startSize.width) * p
        let curH = startSize.height + (endSize.height - startSize.height) * p
        let curSize = CGSize(width: curW, height: curH)
        let origin = WindowGeometry.centeredOrigin(windowSize: curSize, visibleFrame: visible)
        // centeredOrigin 会把原点四舍五入为整数像素，故窗口中心与 visibleFrame 中心的偏差
        // 不超过 0.5px（与动画中按帧取整的实际行为一致）。
        #expect(abs(origin.x + curSize.width / 2 - centerX) <= 0.5)
        #expect(abs(origin.y + curSize.height / 2 - centerY) <= 0.5)
    }
}

@Test
func springInterpolationEndpoints() {
    #expect(WindowAnimator.spring(0) == 0)
    #expect(WindowAnimator.spring(1) == 1)
}

@Test
func springMonotonicInRange() {
    // 临界阻尼弹簧近似应单调递增，值域 [0,1]。
    var prev: CGFloat = -1
    for i in 0...30 {
        let v = WindowAnimator.spring(CGFloat(i) / 30.0)
        #expect(v >= -0.0001 && v <= 1.0001)
        #expect(v >= prev || abs(v - prev) < 0.001)
        prev = v
    }
}

// MARK: - Typed outcome / pure tick state

@Test
func tickStateWriterFailureIsTerminalAndEmittedOnce() {
    let start = CGRect(x: 0, y: 0, width: 100, height: 100)
    var state = WindowAnimator.TickState(
        tickCount: 4,
        initialFrame: start,
        monitorsUserDrift: false
    )

    guard case .write(_, let isFinal) = state.next(currentFrame: start) else {
        Issue.record("first tick should request a write")
        return
    }
    #expect(isFinal == false)
    #expect(state.recordWrite(frame: start, succeeded: false, isFinal: isFinal) == .writerFailed)
    #expect(state.outcome == .writerFailed)

    // 终态只发出一次：后续 tick 和重复写入确认都不能再次产生 completion outcome。
    #expect(state.next(currentFrame: start) == .none)
    #expect(state.recordWrite(frame: start, succeeded: false, isFinal: false) == nil)
}

@Test
func tickStateFinalWriteSuccessFinishesExactlyOnce() {
    let start = CGRect(x: 0, y: 0, width: 100, height: 100)
    let end = CGRect(x: 200, y: 100, width: 100, height: 100)
    var state = WindowAnimator.TickState(
        tickCount: 1,
        initialFrame: start,
        monitorsUserDrift: false
    )

    guard case .write(_, let firstIsFinal) = state.next(currentFrame: start) else {
        Issue.record("first tick should request a non-final write")
        return
    }
    #expect(firstIsFinal == false)
    #expect(state.recordWrite(frame: start, succeeded: true, isFinal: firstIsFinal) == nil)

    guard case .write(let progress, let finalIsFinal) = state.next(currentFrame: start) else {
        Issue.record("second tick should request the final write")
        return
    }
    #expect(progress == 1)
    #expect(finalIsFinal == true)
    #expect(state.recordWrite(frame: end, succeeded: true, isFinal: finalIsFinal) == .finished)
    #expect(state.next(currentFrame: end) == .none)
    #expect(state.recordWrite(frame: end, succeeded: true, isFinal: true) == nil)
}

@Test
func tickStateFinalWriteFailureReportsWriterFailedExactlyOnce() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var state = WindowAnimator.TickState(
        tickCount: 1,
        initialFrame: frame,
        monitorsUserDrift: false
    )

    guard case .write(_, let firstIsFinal) = state.next(currentFrame: frame) else {
        Issue.record("first tick should request a non-final write")
        return
    }
    #expect(state.recordWrite(frame: frame, succeeded: true, isFinal: firstIsFinal) == nil)

    guard case .write(_, let finalIsFinal) = state.next(currentFrame: frame) else {
        Issue.record("second tick should request the final write")
        return
    }
    #expect(finalIsFinal == true)
    #expect(state.recordWrite(frame: frame, succeeded: false, isFinal: finalIsFinal) == .writerFailed)
    #expect(state.next(currentFrame: frame) == .none)
    #expect(state.recordWrite(frame: frame, succeeded: false, isFinal: true) == nil)
}

@Test
func tickStateSustainedUserDriftInterruptsWithoutAnotherWrite() {
    let written = CGRect(x: 0, y: 0, width: 100, height: 100)
    let userMoved = CGRect(x: 200, y: 0, width: 100, height: 100)
    var state = WindowAnimator.TickState(
        tickCount: 20,
        initialFrame: written,
        monitorsUserDrift: true
    )

    // 第一帧属于启动宽限，不参与漂移判定。
    guard case .write(_, let firstIsFinal) = state.next(currentFrame: userMoved) else {
        Issue.record("first tick should request a write")
        return
    }
    #expect(state.recordWrite(frame: written, succeeded: true, isFinal: firstIsFinal) == nil)

    for _ in 0..<(WindowAnimator.jumpAbortConsecutiveTicks - 1) {
        guard case .write(_, let isFinal) = state.next(currentFrame: userMoved) else {
            Issue.record("drift should not interrupt before the configured consecutive threshold")
            return
        }
        #expect(state.recordWrite(frame: written, succeeded: true, isFinal: isFinal) == nil)
    }

    #expect(state.next(currentFrame: userMoved) == .complete(.userInterrupted))
    #expect(state.outcome == .userInterrupted)
    #expect(state.next(currentFrame: userMoved) == .none)
}

@Test
func animateSynchronousWriterSuccessCompletesOnce() {
    let start = CGRect(x: 0, y: 0, width: 100, height: 100)
    let end = CGRect(x: 200, y: 100, width: 100, height: 100)
    var writes: [CGRect] = []
    var outcomes: [WindowAnimator.Outcome] = []

    let timer = WindowAnimator.animate(
        from: start,
        to: end,
        duration: 0,
        writer: { frame in
            writes.append(frame)
            return true
        },
        reader: { nil },
        completion: { outcomes.append($0) }
    )

    #expect(timer == nil)
    #expect(writes == [end])
    #expect(outcomes == [.finished])
}

@Test
func animateSynchronousWriterFailureCompletesOnce() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var writeCount = 0
    var outcomes: [WindowAnimator.Outcome] = []

    let timer = WindowAnimator.animate(
        from: frame,
        to: frame,
        duration: 0,
        writer: { _ in
            writeCount += 1
            return false
        },
        reader: { nil },
        completion: { outcomes.append($0) }
    )

    #expect(timer == nil)
    #expect(writeCount == 1)
    #expect(outcomes == [.writerFailed])
}

@Test
func animateCustomSynchronousFinalWriteReportsTypedOutcomeOnce() {
    let end = CGRect(x: 10, y: 20, width: 300, height: 200)
    var receivedProgress: [CGFloat] = []
    var outcomes: [WindowAnimator.Outcome] = []

    let timer = WindowAnimator.animateCustom(
        duration: 0,
        frameForProgress: { progress in
            receivedProgress.append(progress)
            return end
        },
        writer: { _ in false },
        reader: { nil },
        completion: { outcomes.append($0) }
    )

    #expect(timer == nil)
    #expect(receivedProgress == [1])
    #expect(outcomes == [.writerFailed])
}

@Test
func animateCustomSynchronousSuccessCompletesOnce() {
    let end = CGRect(x: 10, y: 20, width: 300, height: 200)
    var writeCount = 0
    var outcomes: [WindowAnimator.Outcome] = []

    let timer = WindowAnimator.animateCustom(
        duration: 0,
        frameForProgress: { _ in end },
        writer: { frame in
            writeCount += 1
            return frame == end
        },
        reader: { nil },
        completion: { outcomes.append($0) }
    )

    #expect(timer == nil)
    #expect(writeCount == 1)
    #expect(outcomes == [.finished])
}
