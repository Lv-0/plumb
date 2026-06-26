import Foundation
import Testing
@testable import Plumb

// 「连续两次打开」逃生口判定器的时序单测。
// 覆盖：首次调用、间隔小于/等于/大于阈值、触发后清零重新开始一轮。
// 纯逻辑状态机——通过注入 `now` 构造任意时序，无需真实时间。

@Test
func reopenDetectorFirstCallNeverTriggers() {
    var detector = ReopenDetector()
    // 首次调用恒为 false（仅静默记录时间，等待第二次打开）。
    #expect(detector.registerOpen(now: Date(timeIntervalSince1970: 0)) == false)
}

@Test
func reopenDetectorTriggersWithinThreshold() {
    var detector = ReopenDetector()
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(detector.registerOpen(now: start) == false)

    // 间隔 9 秒(< 10 秒阈值)→ 第二次应判定为连续两次打开。
    #expect(detector.registerOpen(now: start.addingTimeInterval(9)) == true)
}

@Test
func reopenDetectorTriggersAtThresholdBoundary() {
    var detector = ReopenDetector()
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(detector.registerOpen(now: start) == false)

    // 恰好等于阈值(闭区间 <=)→ 仍判定为连续两次打开。
    #expect(detector.registerOpen(now: start.addingTimeInterval(ReopenDetector.threshold)) == true)
}

@Test
func reopenDetectorResetsAfterThreshold() {
    var detector = ReopenDetector()
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(detector.registerOpen(now: start) == false)

    // 超过阈值 → 第二次被当作新一轮的「第一次打开」，不触发。
    #expect(detector.registerOpen(now: start.addingTimeInterval(ReopenDetector.threshold + 1)) == false)
}

@Test
func reopenDetectorClearsAfterTrigger() {
    var detector = ReopenDetector()
    let t0 = Date(timeIntervalSince1970: 1_000)

    // 凑齐两次 → 触发(返回 true)。
    #expect(detector.registerOpen(now: t0) == false)
    #expect(detector.registerOpen(now: t0.addingTimeInterval(5)) == true)

    // 触发后应清零：紧接的第三次打开(即使仍在窗口内)是新一轮的「第一次」，返回 false。
    #expect(detector.registerOpen(now: t0.addingTimeInterval(6)) == false)

    // 第四次打开(与第三次间隔在窗口内)才再次触发，完成新一轮。
    #expect(detector.registerOpen(now: t0.addingTimeInterval(10)) == true)
}

@Test
func reopenDetectorRespectsArbitraryLongGap() {
    var detector = ReopenDetector()
    let t0 = Date(timeIntervalSince1970: 1_000)
    #expect(detector.registerOpen(now: t0) == false)

    // 间隔 1 小时(远超阈值)→ 不触发，重新计数。
    #expect(detector.registerOpen(now: t0.addingTimeInterval(3600)) == false)
}
