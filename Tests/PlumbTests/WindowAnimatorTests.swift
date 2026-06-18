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
    // 默认 0.28s @ 120Hz ≈ 33.6 => 34 帧，且不少于 2。
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
