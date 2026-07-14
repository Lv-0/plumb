import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ReopenDetector
//
// 模块角色：菜单栏图标隐藏时的「连续两次打开」逃生口判定（纯逻辑，无 macOS 依赖）。
//
// 职责：
//   - 记录上一次「应用被打开」的时间；当本次打开距上次 ≤ threshold 秒时，判定为
//     「连续两次打开」→ 返回 true（由 AppDelegate 转译为弹出设置）。
//   - 触发后清零计数，避免第三次打开再次误触发。
//   - 超过 threshold 秒重新开始一轮（第一次打开静默记录时间）。
//
// 信号来源：`applicationShouldHandleReopen`（每次 LaunchServices 打开都投递，详见
// AppDelegate 字段注释）。threshold=10s：菜单栏图标隐藏后用户经 Finder/启动台/Spotlight
// 重新打开，两次打开间隔可能数秒，10 秒窗口给足操作时间；误判的代价只是多弹一次设置窗口
// （关掉即可，无副作用），故宁可宽裕。
//
// 设计：原判定逻辑内联在 AppDelegate 里（与 NSApplication 强耦合），无法单测。此处抽出为
// 纯 struct（沿用 WindowGeometry 的纯函数风格），注入 `now` 取时，可任意构造时序验证。
// ─────────────────────────────────────────────────────────────────────────────

/// 「连续两次打开」判定器：纯逻辑状态机，无 macOS 依赖，可单测。
struct ReopenDetector {
    /// 连续两次打开的判定窗口（秒）。超过此间隔重新计数。
    static let threshold: TimeInterval = 10

    /// 上一次「应用被打开」的时间；nil 表示当前处于「等待第一次打开」状态。
    private var lastOpen: Date?

    /// 记录一次「应用被打开」事件，并判定是否构成「连续两次打开」。
    ///
    /// - Parameter now: 当前时间，默认取 `Date()`；测试中注入任意时刻构造时序。
    /// - Returns: true = 距上次打开 ≤ threshold 秒，已检测到连续两次打开，应弹出设置；
    ///   false = 这是新一轮的第一次打开（或首次调用），仅静默记录时间。
    ///
    /// 返回 true 时会清零 `lastOpen`，使后续第三次打开重新开始一轮，避免误触发。
    mutating func registerOpen(now: Date = Date()) -> Bool {
        if let last = lastOpen {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= 0, elapsed <= Self.threshold {
                lastOpen = nil  // 清零：避免紧接其后的第三次打开被误判为「连续两次」
                return true
            }
        }
        lastOpen = now
        return false
    }
}
