import Testing
import Foundation
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateCoordinatorTests
//
// 覆盖「打开设置时自动检查更新」路径，核心不变量：
//   打开设置触发的检查【不能】被后台 6h 节流（backgroundCheckMinInterval）吞掉——
//   否则与文案「打开设置时自动检查」不符。
//
// 设计：通过 UpdateCoordinator.init(checker:) 注入带计数 fetcher 的 checker（复用既有
// ManifestFetcher 抽象），coordinator 暴露 checkerCallCount 供测试观测。生产 .shared 仍用
// 默认 URLSession fetcher（不触网）。
// ─────────────────────────────────────────────────────────────────────────────

@Suite("UpdateCoordinator settings-open check", .serialized)
struct UpdateCoordinatorSettingsOpenTests {

    /// 每个测试结束清理两个节流时间戳，避免 UserDefaults.standard 跨测试/跨次运行残留
    ///（写入的 otaLastCheckTimestamp 等会让后续测试的 settings-open 短节流误命中）。
    /// 配合每测试开头的 resetThrottleTimestamps()，确保节流状态可重现。
    private func clearThrottleOnExit() {
        UserDefaults.standard.removeObject(forKey: UpdateConfig.lastCheckKey)
        UserDefaults.standard.removeObject(forKey: UpdateConfig.settingsOpenCheckLastKey)
    }

    /// 记录 fetch 调用次数的 fetcher（计数器是 actor 隔离的安全整数，避免 NSLock 在 async 不可用）。
    private actor FetchCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private struct CountingFetcher: ManifestFetcher, Sendable {
        let counter: FetchCounter
        func fetch() async throws -> Data {
            await counter.increment()
            // 返回与当前版本相等 → upToDate，避免触发 notifyAvailable 模态弹窗。
            return Data(#"{"version":"0.0.0","url":"https://x/y.zip","sha256":"a","notes":{"en":"n"},"minOS":"0.0.0"}"#.utf8)
        }
    }

    /// 后台节流时间戳写入辅助：模拟「后台检查刚发生不久」（6h 窗口内）。
    private func seedBackgroundThrottle(date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: UpdateConfig.lastCheckKey)
    }

    /// 清空两个节流时间戳（后台 + settings-open），消除测试间的 UserDefaults 污染。
    /// UserDefaults.standard 跨测试持久，若不清理，先跑的测试写入的时间戳会让后跑的测试
    /// 命中意外节流（settings-open 短节流尤其敏感）。
    private func resetThrottleTimestamps() {
        UserDefaults.standard.removeObject(forKey: UpdateConfig.lastCheckKey)
        UserDefaults.standard.removeObject(forKey: UpdateConfig.settingsOpenCheckLastKey)
    }

    @Test("settings-open check proceeds even when 6h background throttle is fresh")
    func settingsOpenCheckNotBlockedByBackgroundThrottle() async {
        defer { clearThrottleOnExit() }
        // 模拟：后台检查刚发生（6h 节流窗口内）→ checkForUpdatesInBackground 必须跳过；
        //       但 checkForUpdatesWhenOpeningSettings 必须仍然发起检查。
        let counter = FetchCounter()
        let checker = UpdateChecker(fetcher: CountingFetcher(counter: counter))
        let coordinator = await UpdateCoordinator(checker: checker)
        await coordinator.setAutoCheckEnabled(true)
        resetThrottleTimestamps()
        seedBackgroundThrottle()

        // 后台路径被 6h 节流吞掉 → 不应调用 checker。
        await coordinator.checkForUpdatesInBackground()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let bgCalls = await counter.count
        #expect(bgCalls == 0, "background path must be throttled when 6h window is fresh")

        // 设置打开路径：必须【不被】6h 节流吞掉 → 应调用 checker。
        await coordinator.checkForUpdatesWhenOpeningSettings()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let calls = await counter.count

        #expect(calls >= 1, "settings-open check must run even when background throttle is fresh")
    }

    @Test("settings-open check respects autoCheckUpdatesProvider disabled")
    func settingsOpenCheckRespectsAutoCheckDisabled() async {
        defer { clearThrottleOnExit() }
        let counter = FetchCounter()
        let checker = UpdateChecker(fetcher: CountingFetcher(counter: counter))
        let coordinator = await UpdateCoordinator(checker: checker)
        await coordinator.setAutoCheckEnabled(false)
        resetThrottleTimestamps()
        seedBackgroundThrottle(date: Date().addingTimeInterval(-999_999)) // 很久以前，排除节流因素

        await coordinator.checkForUpdatesWhenOpeningSettings()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let calls = await counter.count
        #expect(calls == 0, "settings-open check must be skipped when auto-check disabled")
    }

    @Test("settings-open check has its own short throttle separate from background 6h")
    func settingsOpenCheckSeparateThrottle() async {
        defer { clearThrottleOnExit() }
        // 后台节流新鲜，但 settings-open 用独立的短节流：第一次打开设置必须检查。
        let counter = FetchCounter()
        let checker = UpdateChecker(fetcher: CountingFetcher(counter: counter))
        let coordinator = await UpdateCoordinator(checker: checker)
        await coordinator.setAutoCheckEnabled(true)
        resetThrottleTimestamps()
        seedBackgroundThrottle()

        await coordinator.checkForUpdatesWhenOpeningSettings()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let firstCalls = await counter.count
        #expect(firstCalls >= 1, "first settings-open check must run")

        // 立即再次打开设置（极短时间内）：settings-open 自身短节流应避免重复请求，
        // 证明它有自己的节流（独立于后台 6h 节流，但也不是无限触发）。
        await coordinator.checkForUpdatesWhenOpeningSettings()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let secondCalls = await counter.count
        #expect(secondCalls == firstCalls, "settings-open should throttle rapid reopens independently")
    }
}
