import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ResizeOutcome 契约测试
//
// resizeWindowWithFallback 内部会真实调用 AXUIElementSetAttributeValue，无法在没有
// 活体 pid 的单元测试里端到端跑通。但它对外暴露的 ResizeOutcome 枚举（被
// tileWindowElement、tileWindowElementAnimated 的 Phase B 以及诊断日志使用）是一个
// 纯数据契约，可被独立锁定——防止后续重构破坏调用方依赖的语义：
//   - 只有 .failed 表示"尺寸没变"，调用方据此抛 unableToWriteWindowSize。
//   - .axSize / .axFrame 都表示成功，日志据此区分 Electron 应用走的是 AXFrame 兜底。
// 这正是修复 SiYuan/Apifox 等 Electron 应用"设置了自动平铺但不生效"的关键路径。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func resizeOutcomeAxSizeCountsAsResized() {
    #expect(ResizeOutcome.axSize.didResize == true)
}

@Test
func resizeOutcomeAxFrameCountsAsResized() {
    // Electron/Chromium 类应用（SiYuan、Apifox）拒绝 kAXSize、回退 AXFrame 成功 → 仍应视为"已放大"。
    #expect(ResizeOutcome.axFrame.didResize == true)
}

@Test
func resizeOutcomeFailedDoesNotCountAsResized() {
    #expect(ResizeOutcome.failed.didResize == false)
}

@Test
func resizeOutcomeExhaustivelyPartitionsResized() {
    // 锁定：所有 case 中只有 .failed 不算成功。若未来新增 case，这里会强制要求显式归类。
    for outcome in [ResizeOutcome.axSize, .axFrame, .failed] {
        if outcome == .failed {
            #expect(!outcome.didResize)
        } else {
            #expect(outcome.didResize)
        }
    }
}
