import AppKit
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WindowCenteringService
//
// 模块角色：窗口几何引擎（项目的核心复杂度所在）。
//
// 职责：
//   - 读取前台窗口的位置/尺寸（AXPosition / AXSize），探测它使用的"坐标系"，
//     计算居中或平铺目标，再写回（AXPosition / AXSize / AXFrame，逐级兜底）。
//   - 提供四条对外路径：
//       centerWindowElement(_:)          —— 瞬时居中（无动画，仅写一次）。
//       centerWindowElementAnimated(_:)  —— 弹簧动画居中（手动"立即居中"使用）。
//       tileWindowElement(_:)            —— 瞬时平铺（先设尺寸再定位，逐空间兜底）。
//       tileWindowElementAnimated(_:)    —— 两阶段动画平铺：先移到左上锚点、再保持锚点扩大。
//
// 坐标空间问题（本项目最棘手的复杂度）：
//   macOS 各 app 报告窗口位置时使用的坐标系不统一，单个 AXPosition 值可能落在
//   四种空间之一：globalBottomLeft / globalTopLeft / localBottomLeft / localTopLeft
//   （原点不同、Y 轴方向不同）。本服务通过"窗口中心点归属选屏 + 逐空间重叠评分 +
//   CGWindowList 辅助信号 + 按 PID 缓存"来稳定地推断正确的空间与屏幕。
//
// 不变量 / 关键约定：
//   - 全屏窗口一律跳过（AXFullScreen 属性 + 几何比对双判定）。
//   - 动画期间检测"用户拖动"：连续 jumpAbortConsecutiveTicks 帧偏离写入位置才中止，
//     以过滤 macOS 激活动画造成的瞬时弹动（见 WindowAnimator）。
//   - 切换 app 时全局动画租约与所有定时器都被 abortActiveAnimations() 清空。
//
// 与 WindowEventObserver 的边界：
//   Observer 决定"何时、对哪个窗口"；本服务决定"如何算坐标、如何写 AX"。
// ─────────────────────────────────────────────────────────────────────────────

enum WindowCenteringError: LocalizedError {
    case accessibilityPermissionMissing
    case noFrontmostApplication
    case noWindow
    case fullscreenWindow
    case unableToReadWindowFrame
    case unableToWriteWindowSize
    case unableToWriteWindowPosition

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return L10n.errAccessibilityPermissionMissing
        case .noFrontmostApplication:
            return L10n.errNoFrontmostApplication
        case .noWindow:
            return L10n.errNoWindow
        case .fullscreenWindow:
            return L10n.errFullscreenWindow
        case .unableToReadWindowFrame:
            return L10n.errUnableToReadWindowFrame
        case .unableToWriteWindowSize:
            return L10n.errUnableToWriteWindowSize
        case .unableToWriteWindowPosition:
            return L10n.errUnableToWriteWindowPosition
        }
    }
}

enum WindowSelectionPolicy {
    case focusedOnly
    case focusedOrAnyNonFullscreen
}

/// 窗口尺寸写入的路径与结果。
///
/// `resizeWindowWithFallback` 先尝试 `kAXSizeAttribute`；Electron/Chromium 类应用
/// （如 SiYuan、Apifox）拒绝单独写 kAXSize 但接受 AXFrame，此时回退到 AXFrame
///（连同当前 origin 一起写回，origin 不变）。返回 `.failed` 表示两条路径都失败。
/// 该枚举也用于诊断日志，区分窗口最终是通过哪条路径被放大的。
enum ResizeOutcome {
    /// kAXSizeAttribute 直接写入成功（标准窗口、大多数原生应用）。
    case axSize
    /// 回退到 AXFrame 写入成功（Electron/Chromium 类应用）。
    case axFrame
    /// 两条路径都失败（窗口不可调整尺寸或 AX 不可达）。
    case failed

    /// 尺寸是否被成功改变。
    var didResize: Bool { self != .failed }
}

/// Whether an animated layout request actually acquired the global animation slot.
///
/// Callers use this result to distinguish real work from a busy/no-op request. A
/// busy request must not consume retry budget or be marked as completed.
enum WindowAnimationStartResult: Equatable {
    case started
    /// The request completed before returning. `didWriteGeometry` separates a
    /// true no-op (already at target) from the synchronous fallback path, which
    /// really writes AX geometry and can therefore emit delayed move events.
    case completedSynchronously(didWriteGeometry: Bool)
    case busy

    var isCompletedSynchronously: Bool {
        if case .completedSynchronously = self { return true }
        return false
    }

    var synchronousWriteOccurred: Bool {
        if case let .completedSynchronously(didWriteGeometry) = self {
            return didWriteGeometry
        }
        return false
    }
}

/// Pure policy for the hand-off between the timer-driven move (Phase A) and the
/// service-owned resize sequence (Phase B). Only a genuinely finished move may
/// advance; write failures and user interruption are terminal for this request.
enum TilePhaseAOutcomePolicy {
    static func shouldEnterPhaseB(after outcome: WindowAnimator.Outcome) -> Bool {
        outcome == .finished
    }
}

/// Small PID-scoped cache primitive. Keeping invalidation in the value type makes
/// PID reuse and application-termination cleanup independently testable.
struct ProcessScopedCache<Value> {
    private var values: [pid_t: Value] = [:]

    subscript(pid: pid_t) -> Value? {
        get { values[pid] }
        set { values[pid] = newValue }
    }

    @discardableResult
    mutating func removeValue(for pid: pid_t) -> Value? {
        values.removeValue(forKey: pid)
    }

    mutating func removeAll() {
        values.removeAll()
    }

    var count: Int { values.count }
}

/// Pure global single-flight gate. A lease, rather than a bare window key, owns
/// the slot so a delayed completion from an aborted request cannot release a
/// newer request for the same window key.
struct WindowAnimationSlot {
    struct Lease: Equatable {
        let key: String
        fileprivate let generation: UInt64
    }

    private(set) var activeLease: Lease?
    private var nextGeneration: UInt64 = 0

    var activeKey: String? { activeLease?.key }

    mutating func acquire(key: String) -> Lease? {
        guard activeLease == nil else { return nil }
        nextGeneration &+= 1
        let lease = Lease(key: key, generation: nextGeneration)
        activeLease = lease
        return lease
    }

    @discardableResult
    mutating func release(_ lease: Lease) -> Bool {
        guard activeLease == lease else { return false }
        activeLease = nil
        return true
    }

    mutating func cancel() {
        activeLease = nil
    }
}

/// Pure rectangle-to-screen overlap selection used by the CG window-bounds path.
/// Keeping this independent of `NSScreen` makes the zero-overlap contract deterministic
/// and unit-testable without a particular physical display arrangement.
enum WindowScreenOverlapSelection {
    struct Match: Equatable {
        let index: Int
        let area: CGFloat
    }

    static func bestMatch(
        for rect: CGRect,
        in screenFrames: [CGRect],
        tieTolerance: CGFloat = 0.5
    ) -> Match? {
        guard !rect.isNull, !rect.isEmpty, !screenFrames.isEmpty else { return nil }

        let overlaps = screenFrames.map { intersectionArea(rect, $0) }
        guard let bestArea = overlaps.max(), bestArea > 0 else { return nil }

        let tolerance = max(0, tieTolerance)
        let candidates = overlaps.indices.filter {
            overlaps[$0] > 0 && abs(overlaps[$0] - bestArea) <= tolerance
        }
        guard let fallback = candidates.first else { return nil }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let chosen = candidates.first(where: { screenFrames[$0].contains(center) }) ?? fallback
        return Match(index: chosen, area: overlaps[chosen])
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        guard !rhs.isNull, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

@MainActor
final class WindowCenteringService {
    private enum RawSpace {
        case globalBottomLeft
        case globalTopLeft
        case localBottomLeft
        case localTopLeft
    }

    private struct WindowContext {
        let screen: NSScreen
        let space: RawSpace
        let overlap: CGFloat
        let currentGlobalRect: CGRect
    }

    private struct ContextCandidate {
        let screen: NSScreen
        let space: RawSpace
        let globalRect: CGRect
        let overlap: CGFloat
        let distance2: CGFloat
    }

    /// 共享的居中目标解算结果：非动画与动画路径共用，避免发散。
    private struct CenterTarget {
        let context: WindowContext
        let visibleFrame: CGRect
        let centeredBottomLeftOrigin: CGPoint
        let targetAXOrigin: CGPoint
    }

    // When a window is mostly off-screen, overlap-based inference becomes ambiguous.
    // Cache the last reliable coordinate system per PID to keep behavior stable.
    private var cachedSpaceByPID = ProcessScopedCache<RawSpace>()
    private var cachedDisplayByPID = ProcessScopedCache<CGDirectDisplayID>()

    // MARK: - Phase-B 平铺动画时序参数
    //
    // 阶段 B（架构变更，3+ 次 per-frame 尝试失败后的正确方案）：
    // 高频 per-frame 写 size 会导致 app 每帧重新布局、把窗口"弹回"到一个非目标位置，
    // 使 macOS 把尺寸 clamp 到"不溢出屏"的小值（"4 边铺不满"根因）。
    // 实测有效方案：先把 position 移到最终平铺原点（一次写），给 app 一段 settle 时间，
    // 再分少量大步把尺寸插值到目标（每步之间也 settle），最后强制 pos+size 落地。
    //
    // 提速调整（保守、绝不回归）：步数与步进可压，但 settle 引入延迟绝不动——它是防弹回的关键。
    // 历史值：steps=6 / stepIntervalMs=120ms → Phase-B ≈ 0.97s。
    // 当前值：steps=4 / stepIntervalMs=90ms  → Phase-B ≈ 0.61s（省 ~0.36s）。
    // 若某 app 出现铺不满/弹回，单独回退这两个值即可（互不影响）。

    /// Phase-B 分步推进的尺寸插值步数。每步线性逼近目标尺寸，最后一步强制落地兜底。
    private static let tilePhaseBSteps = 4

    /// Phase-B 每步之间的 settle 间隔（毫秒）。必须远大于一帧（60Hz≈16.7ms），否则会触发
    /// app 每帧重布局导致弹回。90ms ≈ 5 帧，满足约束。
    private static let tilePhaseBStepIntervalMs: Int = 90

    /// Phase-B 启动前的 settle 引入延迟（毫秒）：先把 position 写到平铺原点，给 app 这段时间
    /// 稳定，再开始扩大尺寸。**这是防弹回的关键防线，不要压缩。**
    private static let tilePhaseBLeadInMs: Int = 250

    // MARK: - Phase-B 丝滑放大时序参数
    //
    // 丝滑模式（默认）：以高频帧（60Hz）驱动尺寸放大，用 ease-out 曲线插值，替代稳健模式的
    // “4 步线性跳跃”。左上角锚定、向右下扩展（origin 不变，仅 width/height 变化）。
    // 60Hz × 0.30s ≈ 18 帧 ease-out，观感为连续平滑的“落位”放大。
    //
    // 防弹回（回归防线）：高频写 size 仍可能触发某些 app 每帧重布局导致“铺不满/弹回”（历史上
    // 踩过的坑，故有上方 250ms settle）。丝滑模式每帧读回实际尺寸，若连续落后写入值超过阈值，
    // 立即降级到稳健大步模式（`runPhaseBRobust`），保证敏感 app（Electron 类、终端类）不回归。

    /// 丝滑放大总时长（秒）。
    private static let smoothPhaseBDuration: TimeInterval = 0.30

    /// 丝滑放大写尺寸的帧率（Hz）。60Hz 平衡了流畅度与“不让 app 每帧过载布局”——120Hz 会显著
    /// 增加弹回概率，故刻意低于 Phase-A 的 120Hz。
    private static let smoothPhaseBTickHz: Int = 60

    /// 丝滑放大启动前的 settle 引入延迟（毫秒）。稳健模式需 250ms 给大步之间稳定；帧驱动因每步
    /// 变化小（ease-out 单帧增量远小于一个大步），可大幅压缩。保留少量引入延迟以先稳定布局。
    private static let smoothPhaseBLeadInMs: Int = 60

    /// 弹回判定阈值（px）：若实际尺寸在某一轴上落后于写入值超过此值，计为一帧“弹回”。
    /// 调高自 24px——60Hz 写入时 app 实际尺寸因 AX 异步延迟天然落后写入值 24~40px，属正常 lag
    /// 而非真弹回；24px 阈值会把正常 lag 误判为弹回、频繁降级，导致「首次打开不平铺」（didWindowActuallyTile
    /// 因降级后 250ms 重启而达不到目标）。
    private static let smoothPhaseBBounceBackPx: CGFloat = 48

    /// 连续多少帧弹回才触发降级。调高自 2 帧——要求更多连续帧可避免对正常 lag 的误判。
    private static let smoothPhaseBBounceBackConsecutiveTicks: Int = 3

    /// 仅当进度超过此阈值后才开始计弹回。前段（app 尚未真正开始放大、AX 延迟累积）的实际尺寸
    /// 必然落后写入值，这是物理正常的；只有接近末段仍大幅落后才可能是真弹回。
    private static let smoothPhaseBBounceBackMinProgress: CGFloat = 0.6

    /// 大跨度放大直接走稳健 Phase-B。Pages/Numbers 新文稿与极小 Safari 的共同点是从较小
    /// 起始尺寸放到接近平铺目标，60Hz 连续写 size 容易让目标 app 的 layout/AX 读回滞后；
    /// 这种场景牺牲一点动画丝滑度，优先使用历史验证过的分步 settle 路径。
    nonisolated private static let robustPhaseBAreaRatioThreshold: CGFloat = 0.70
    nonisolated private static let robustPhaseBAxisDeltaThreshold: CGFloat = 320

    // MARK: - Phase-B 收尾 settle-and-recheck 时序参数
    //
    // 动画末帧（finalizePhaseB）读回尺寸时，部分重型 app（如 Pages 新建文稿）的内部 layout
    // 引擎跟不上 60Hz 写入——读回的是 layout 还没追平的旧尺寸（实测 Pages 60Hz 突发下回读恒为
    // 1356，但单次写 + ~1s settle 能完美达到目标 1480）。若此时直接锚定+接受，会把滞后尺寸当
    // 成最终值，窗口「放大了一部分」。
    //
    // settle-and-recheck：保持动画锁，多轮 × 较短间隔地重写 endSize 并重读，给 layout 追平时间。
    // 既覆盖 Pages 的 ~1s layout 追平，又避免单次长延迟阻塞动画锁。

    /// 每轮 settle 之间的延迟（毫秒）。300ms 足以让 Pages layout 追平一帧写入。
    private static let settleDelayMs: Int = 300

    /// settle 最大轮数。300ms × 5 ≈ 1.5s，覆盖 Pages/Numbers/Safari 从小窗放大时的 layout 追平；
    /// 仍未达成则视为 app 真硬限
    /// （终端按字符网格），走 top-left 锚定接受实际尺寸（与无 settle 的兜底语义一致）。
    private static let settleMaxRounds: Int = 5

    /// 全局动画租约。底层只有一个 Phase-B timer ownership channel，因此不是按窗口单飞，
    /// 而是整个 service 同时最多一个动画请求。
    private var animationSlot = WindowAnimationSlot()

    /// 进行中的动画定时器句柄（Phase-A 由 WindowAnimator 返回；Phase-B 平铺推进由本类持有）。
    /// 切换 app 时通过 `abortActiveAnimations()` 全部取消，避免 zombie 定时器在后台继续
    /// 移动已非前台 app 的窗口（"切走后 Safari 跑到另一个屏幕"的根因）。
    private var activeAnimatorTimers: [DispatchSourceTimer] = []
    /// 平铺 Phase-B 的分步推进定时器（独立追踪，因其不在 WindowAnimator 体系内）。
    private var activeTileTimer: DispatchSourceTimer?

    /// 是否有任意窗口动画正在进行中（供观察者决定是否需要重试）。
    var isAnyAnimationInProgress: Bool { animationSlot.activeLease != nil }

    /// 切换 app / 手动中止时调用：立即停止所有进行中的动画，窗口停在最后一帧已写入的位置
    ///（不回弹、不再写）。消除 zombie 定时器在非前台时继续移动窗口的缺陷。
    func abortActiveAnimations() {
        let hadActive = animationSlot.activeLease != nil || !activeAnimatorTimers.isEmpty || activeTileTimer != nil
        activeTileTimer?.cancel()
        activeTileTimer = nil
        for timer in activeAnimatorTimers {
            timer.cancel()
        }
        activeAnimatorTimers.removeAll()
        // 清空锁，确保后续动画能正常启动（被 cancel 的定时器不会触发其 completion，故主动清空）。
        animationSlot.cancel()
        if hadActive {
            DiagnosticLog.debug("abortActiveAnimations: stopped all in-flight animations")
        }
    }

    /// Invalidates coordinate-space evidence owned by a process. Call this when an
    /// application terminates so a future process that reuses the same PID cannot
    /// inherit stale display/coordinate-space decisions.
    func invalidateCachedWindowContext(for pid: pid_t) {
        cachedSpaceByPID.removeValue(for: pid)
        cachedDisplayByPID.removeValue(for: pid)
        DiagnosticLog.debug("window-context-cache: invalidated pid=\(pid)")
    }

    /// Clears all process-derived coordinate-space evidence. This is intended for
    /// service teardown or a complete display-topology reset.
    func invalidateAllCachedWindowContexts() {
        cachedSpaceByPID.removeAll()
        cachedDisplayByPID.removeAll()
        DiagnosticLog.debug("window-context-cache: invalidated all")
    }

    nonisolated static func shouldUseRobustPhaseB(startSize: CGSize, endSize: CGSize) -> Bool {
        guard endSize.width > 0, endSize.height > 0 else { return false }

        let startArea = max(0, startSize.width) * max(0, startSize.height)
        let endArea = endSize.width * endSize.height
        if endArea > 0, startArea / endArea < robustPhaseBAreaRatioThreshold {
            return true
        }

        return abs(endSize.width - startSize.width) >= robustPhaseBAxisDeltaThreshold ||
            abs(endSize.height - startSize.height) >= robustPhaseBAxisDeltaThreshold
    }

    func centerFrontmostWindow(selectionPolicy: WindowSelectionPolicy = .focusedOrAnyNonFullscreen) throws {
        guard AccessibilityPermission.ensureTrusted(prompt: false) else {
            throw WindowCenteringError.accessibilityPermissionMissing
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw WindowCenteringError.noFrontmostApplication
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        let focusedWindow = focusedWindowElement(for: appElement)
        let allWindows = windowElements(for: appElement)
        guard let windowElement = selectCenterableWindow(
            focused: focusedWindow,
            windows: allWindows,
            selectionPolicy: selectionPolicy
        ) else {
            if let focusedWindow, isFullscreenWindow(focusedWindow) {
                throw WindowCenteringError.fullscreenWindow
            }
            throw WindowCenteringError.noWindow
        }

        // 手动"立即居中"同样采用丝滑动画。
        try centerWindowElementAnimated(windowElement, pid: app.processIdentifier)
    }

    func centerWindowElement(_ windowElement: AXUIElement, pid: pid_t? = nil, appElement: AXUIElement? = nil) throws {
        if let appElement, isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }
        if isFullscreenWindow(windowElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let primaryTopY = primaryScreenTopY()
        let context: WindowContext?
        if let pid, let cgContext = detectWindowContextUsingCG(windowElement: windowElement, pid: pid, rawPosition: currentPosition, windowSize: windowSize, primaryTopY: primaryTopY) {
            context = cgContext
        } else {
            context = detectWindowContext(rawPosition: currentPosition, windowSize: windowSize, pid: pid, primaryTopY: primaryTopY)
        }

        guard let context else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let centeredBottomLeftOrigin = WindowGeometry.centeredOrigin(windowSize: windowSize, visibleFrame: visibleFrame)
        let targetAXOrigin = toAXOrigin(
            bottomLeftOrigin: centeredBottomLeftOrigin,
            windowSize: windowSize,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryTopY
        )

        if setPointAttribute(kAXPositionAttribute as CFString, value: targetAXOrigin, on: windowElement) {
            return
        }

        // If the window is far out-of-bounds, some apps reject "ideal" coordinates.
        // Try bringing it back into the visible region first, then re-apply centering.
        let backInVisible = WindowGeometry.constrainedOrigin(origin: context.currentGlobalRect.origin, windowSize: windowSize, bounds: visibleFrame)
        let backAXOrigin = toAXOrigin(
            bottomLeftOrigin: backInVisible,
            windowSize: windowSize,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryTopY
        )
        _ = setPointAttribute(kAXPositionAttribute as CFString, value: backAXOrigin, on: windowElement)

        if setPointAttribute(kAXPositionAttribute as CFString, value: targetAXOrigin, on: windowElement) {
            return
        }

        // Last resort: some windows accept AXFrame but not AXPosition.
        let frameRect = CGRect(origin: targetAXOrigin, size: windowSize)
        if setRectAttribute("AXFrame" as CFString, value: frameRect, on: windowElement) {
            return
        }

        throw WindowCenteringError.unableToWriteWindowPosition
    }

    /// 带动画的居中：与 `centerWindowElement` 使用相同的坐标空间探测与目标解算，
    /// 然后用 `WindowAnimator` 把窗口从当前位置丝滑滑到居中位置（仅移动，不改尺寸）。
    @discardableResult
    func centerWindowElementAnimated(
        _ windowElement: AXUIElement,
        pid: pid_t? = nil,
        appElement: AXUIElement? = nil,
        completion: WindowAnimator.Completion? = nil
    ) throws -> WindowAnimationStartResult {
        if let appElement, isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }
        if isFullscreenWindow(windowElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        guard let target = resolveCenterTarget(windowElement: windowElement, pid: pid) else {
            // 解算失败：退回非动画路径（保持原有错误语义）。
            try centerWindowElement(windowElement, pid: pid, appElement: appElement)
            completion?(.finished)
            return .completedSynchronously(didWriteGeometry: true)
        }

        let context = target.context
        let windowSize = CGSize(width: context.currentGlobalRect.width, height: context.currentGlobalRect.height)

        // 动画起点：窗口当前在 AX 坐标系下的原点（与 targetAXOrigin 同空间）。
        let startOrigin = toAXOrigin(
            bottomLeftOrigin: context.currentGlobalRect.origin,
            windowSize: windowSize,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryScreenTopY()
        )
        let endOrigin = target.targetAXOrigin

        // 已在目标位置：直接返回。
        if abs(startOrigin.x - endOrigin.x) < 1, abs(startOrigin.y - endOrigin.y) < 1 {
            completion?(.finished)
            return .completedSynchronously(didWriteGeometry: false)
        }

        let animKey = animationKey(for: windowElement, pid: pid, kind: "center")
        // 全局单飞：底层 Phase-B 仍只有一个 timer ownership channel，任何不同窗口/不同 kind
        // 的并发动画都会覆盖句柄并使 abort 失效。已有动画时显式返回 busy，由上层稍后重试。
        // ⚠️ 不得调用 completion：这是「跳过未执行」而非「真完成」。调用方（如平铺完成回调里的
        // markCentered + processedPIDs.insert）会把假完成当作真完成，提前锁死在错误几何上。
        guard let animationLease = animationSlot.acquire(key: animKey) else {
            DiagnosticLog.debug("center-animator: busy active=\(animationSlot.activeKey ?? "?") skip requested=\(animKey) (no completion)")
            return .busy
        }

        // 用 box 持有定时器引用：completion 闭包需要引用它，但它本身是 animate 的返回值，
        // 不能在声明前被同一作用域的闭包捕获。声明在前、赋值在后即可。
        var animatorTimerBox: DispatchSourceTimer?
        animatorTimerBox = WindowAnimator.animate(
            from: CGRect(origin: startOrigin, size: windowSize),
            to: CGRect(origin: endOrigin, size: windowSize),
            easing: WindowAnimator.spring,
            writer: { [weak self] frame in
                guard let self else { return false }
                guard self.animationSlot.activeLease == animationLease else { return false }
                if self.setPointAttribute(kAXPositionAttribute as CFString, value: frame.origin, on: windowElement) {
                    return true
                }
                // 尝试 AXFrame 兜底。
                return self.setRectAttribute("AXFrame" as CFString, value: frame, on: windowElement)
            },
            reader: { [weak self] in
                guard let self else { return nil }
                guard let p = self.pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
                      let s = self.sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
                else { return nil }
                return CGRect(origin: p, size: s)
            },
            completion: { [weak self] outcome in
                let completedCurrentLease = self?.animationSlot.release(animationLease) ?? false
                // 任一驱动终态都从追踪列表移除（timer 已 cancel，避免句柄堆积）。
                if let timer = animatorTimerBox {
                    self?.activeAnimatorTimers.removeAll { $0 === timer }
                }
                guard completedCurrentLease else {
                    DiagnosticLog.debug("center-animator: ignored stale completion pid=\(pid.map(String.init) ?? "?")")
                    return
                }
                if outcome == .finished {
                    DiagnosticLog.debug("center-animator: finished pid=\(pid.map(String.init) ?? "?")")
                } else {
                    DiagnosticLog.debug("center-animator: stopped outcome=\(outcome) pid=\(pid.map(String.init) ?? "?")")
                }
                completion?(outcome)
            }
        )
        if let animatorTimer = animatorTimerBox {
            activeAnimatorTimers.append(animatorTimer)
        }
        return .started
    }

    func tileWindowElement(_ windowElement: AXUIElement, pid: pid_t? = nil, appElement: AXUIElement? = nil, insets: TileInsets) throws {
        if let appElement, isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }
        if isFullscreenWindow(windowElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let primaryTopY = primaryScreenTopY()
        let context: WindowContext?
        if let pid, let cgContext = detectWindowContextUsingCG(
            windowElement: windowElement,
            pid: pid,
            rawPosition: currentPosition,
            windowSize: windowSize,
            primaryTopY: primaryTopY
        ) {
            context = cgContext
        } else {
            context = detectWindowContext(
                rawPosition: currentPosition,
                windowSize: windowSize,
                pid: pid,
                primaryTopY: primaryTopY
            )
        }

        guard let context else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let targetFrame = WindowGeometry.tiledFrame(visibleFrame: visibleFrame, insets: insets)

        let sizeResult = resizeWindowWithFallback(windowElement, newSize: targetFrame.size)
        if !sizeResult.didResize {
            // Tiling requires resize capability; skip windows that cannot be resized.
            //（覆盖 Electron 应用：kAXSize 写不进但 AXFrame 可写——它们在此不会被判失败。）
            throw WindowCenteringError.unableToWriteWindowSize
        }

        if tileReachedTarget(windowElement, pid: pid, context: context, primaryTopY: primaryTopY, targetFrame: targetFrame) {
            return
        }

        let spaces = prioritizedSpaces(primary: context.space)
        for space in spaces {
            let candidateOrigin = toAXOrigin(
                bottomLeftOrigin: targetFrame.origin,
                windowSize: targetFrame.size,
                screenFrame: context.screen.frame,
                space: space,
                primaryTopY: primaryTopY
            )
            if setPointAttribute(kAXPositionAttribute as CFString, value: candidateOrigin, on: windowElement),
               tileReachedTarget(windowElement, pid: pid, context: context, space: space, primaryTopY: primaryTopY, targetFrame: targetFrame)
            {
                rememberResolvedContext(pid: pid, screen: context.screen, space: space)
                return
            }
        }

        // Last resort: try AXFrame with all coordinate-space candidates.
        for space in spaces {
            let candidateOrigin = toAXOrigin(
                bottomLeftOrigin: targetFrame.origin,
                windowSize: targetFrame.size,
                screenFrame: context.screen.frame,
                space: space,
                primaryTopY: primaryTopY
            )
            let frameRect = CGRect(origin: candidateOrigin, size: targetFrame.size)
            if setRectAttribute("AXFrame" as CFString, value: frameRect, on: windowElement),
               tileReachedTarget(windowElement, pid: pid, context: context, space: space, primaryTopY: primaryTopY, targetFrame: targetFrame)
            {
                rememberResolvedContext(pid: pid, screen: context.screen, space: space)
                return
            }
        }

        throw WindowCenteringError.unableToWriteWindowPosition
    }

    /// 带动画的两阶段平铺：
    ///   阶段 A — 在保持当前尺寸的前提下，把窗口平滑移到平铺目标的左上锚点；
    ///   阶段 B — 保持左上锚点，从当前尺寸平滑扩大到平铺尺寸。
    /// 若窗口不可调整大小，则跳过阶段 B，仅完成左上锚点移动。
    @discardableResult
    func tileWindowElementAnimated(
        _ windowElement: AXUIElement,
        pid: pid_t? = nil,
        appElement: AXUIElement? = nil,
        insets: TileInsets,
        completion: WindowAnimator.Completion? = nil
    ) throws -> WindowAnimationStartResult {
        if let appElement, isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }
        if isFullscreenWindow(windowElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let primaryTopY = primaryScreenTopY()
        let context: WindowContext?
        if let pid, let cgContext = detectWindowContextUsingCG(
            windowElement: windowElement,
            pid: pid,
            rawPosition: currentPosition,
            windowSize: windowSize,
            primaryTopY: primaryTopY
        ) {
            context = cgContext
        } else {
            context = detectWindowContext(
                rawPosition: currentPosition,
                windowSize: windowSize,
                pid: pid,
                primaryTopY: primaryTopY
            )
        }

        guard let context else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let targetFrame = WindowGeometry.tiledFrame(visibleFrame: visibleFrame, insets: insets)
        DiagnosticLog.debug("tile-animator: detect pid=\(pid.map(String.init) ?? "?") rawPos=\(currentPosition) size=\(windowSize) visibleFrame=\(visibleFrame) space=\(context.space) targetFrame=\(targetFrame)")
        // 全局单飞：Phase-B 只有一个 timer ownership channel。任何已有动画（即使是不同窗口
        // 或 center/tile 不同 kind）都必须返回 busy，不能覆盖 singleton state。
        let animKey = animationKey(for: windowElement, pid: pid, kind: "tile")
        guard let animationLease = animationSlot.acquire(key: animKey) else {
            // ⚠️ 不得调用 completion：这是「跳过未执行」而非「真完成」。旧实现调用 completion
            // 会触发调用方的 markCentered + processedPIDs.insert + startTileStabilizationRetries，
            // 把「跳过的这次」当作真完成锁死，并启动新的稳定重试 → 假完成 + 真重试叠加，
            // 是「反复平铺 / 死循环」的根因之一。调用方对跳过一律 no-op。
            DiagnosticLog.debug("tile-animator: busy active=\(animationSlot.activeKey ?? "?") skip requested=\(animKey) (no completion)")
            return .busy
        }

        // 已处于最终目标（或明确接受的锚定 fallback）时无需占用动画槽。
        if tileReachedTarget(
            windowElement,
            pid: pid,
            context: context,
            primaryTopY: primaryTopY,
            targetFrame: targetFrame
        ) {
            _ = animationSlot.release(animationLease)
            completion?(.finished)
            return .completedSynchronously(didWriteGeometry: false)
        }

        let isAnimationLeaseActive: () -> Bool = { [weak self] in
            self?.animationSlot.activeLease == animationLease
        }

        let reader: () -> CGRect? = { [weak self] in
            guard let self else { return nil }
            guard let p = self.pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
                  let s = self.sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
            else { return nil }
            return CGRect(origin: p, size: s)
        }

        let finishActive = { [weak self] in
            guard let self else { return }
            if self.animationSlot.release(animationLease) {
                // 只允许当前 slot owner 清除 timer；过期 continuation 不得破坏后续会话。
                self.activeTileTimer = nil
            }
        }

        // === 阶段 A：以当前尺寸滑到平铺目标原点（左上角锚定，仅移动） ===
        // 关键修复：此前 Phase A 滑到「屏幕中心」、Phase B 再单次写入跳到左上角——那次写入常因
        // app 在 Phase A 结束后仍在 relayout 而被延迟/忽略，导致窗口停在中心开始放大（用户报告
        // 「没有先移到左上角」）。改为 Phase A 直接滑到左上角锚点，消除中间跳变。
        //
        // 几何：保持左上角角点固定在平铺目标左上角 (visibleFrame.minX+insetX, visibleFrame.maxY-insetY)，
        // 对当前窗口尺寸反推左下角 origin。当尺寸增长到 targetSize 时，此 origin 收敛到 targetFrame.origin，
        // 与 Phase B 的 targetAXOrigin 一致，故放大期间 origin 无需再动。
        let insetX = targetFrame.minX - visibleFrame.minX
        let insetY = visibleFrame.maxY - targetFrame.maxY
        let tileOriginForCurrentSize = CGPoint(
            x: visibleFrame.minX + insetX,
            y: visibleFrame.maxY - insetY - windowSize.height
        )
        let tileOriginAXForCurrentSize = toAXOrigin(
            bottomLeftOrigin: tileOriginForCurrentSize,
            windowSize: windowSize,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryTopY
        )

        // 如果当前位置已在平铺原点 2px 内，则跳过阶段 A 直接进入阶段 B。
        let alreadyAtTileOrigin = abs(currentPosition.x - tileOriginAXForCurrentSize.x) < 2 && abs(currentPosition.y - tileOriginAXForCurrentSize.y) < 2

        // 阶段 B 的尺寸能否写入（即窗口是否可调整大小）。
        let canResize = isResizable(windowElement)


        // 若既已在原点又不可调整大小，则无需动画。
        if alreadyAtTileOrigin, !canResize {
            finishActive()
            completion?(.finished)
            return .completedSynchronously(didWriteGeometry: false)
        }

        let runPhaseB: () -> Void = { [weak self] in
            guard let self else { return }
            guard isAnimationLeaseActive() else {
                DiagnosticLog.debug("tile-animator: ignored stale Phase-B handoff pid=\(pid.map(String.init) ?? "?")")
                return
            }
            guard canResize else {
                // 不可调整大小：仅居中即可，阶段 A 已处理。
                finishActive()
                completion?(.finished)
                return
            }

            // 阶段 B 的时序参数见类顶 tilePhaseB* / smoothPhaseB* 常量（含提速调整与回归风险注释）。
            let endSize = targetFrame.size
            let targetAXOrigin = toAXOrigin(
                bottomLeftOrigin: targetFrame.origin,
                windowSize: endSize,
                screenFrame: context.screen.frame,
                space: context.space,
                primaryTopY: primaryTopY
            )

            // Phase A 已把窗口锚到平铺左上角原点（以当前尺寸）；此处不再单次写入 origin（旧实现的
            // 那次写入恰是「窗口停在中心开始放大」bug 的根因——被 Phase A 收尾期的 relayout 拖垮）。
            // 大跨度放大直接走稳健大步模式，避免 Pages/Numbers/Safari 这类窗口在 60Hz 连续写 size
            // 时 layout 追不上，最后被接受为偏小尺寸。
            if Self.shouldUseRobustPhaseB(startSize: windowSize, endSize: endSize) {
                DiagnosticLog.debug("tile-animator: robust Phase-B selected for large resize start=\(windowSize) target=\(endSize) pid=\(pid.map(String.init) ?? "?")")
                runPhaseBRobust(
                    windowElement: windowElement,
                    startSize: windowSize,
                    endSize: endSize,
                    targetAXOrigin: targetAXOrigin,
                    targetFrame: targetFrame,
                    visibleFrame: visibleFrame,
                    context: context,
                    primaryTopY: primaryTopY,
                    pid: pid,
                    animKey: animKey,
                    isAnimationLeaseActive: isAnimationLeaseActive,
                    finishActive: finishActive,
                    completion: completion
                )
                return
            }

            // 进入丝滑放大（默认）。若检测到弹回，会自动降级到稳健大步模式。
            runPhaseBSmooth(
                windowElement: windowElement,
                startSize: windowSize,
                endSize: endSize,
                targetAXOrigin: targetAXOrigin,
                targetFrame: targetFrame,
                visibleFrame: visibleFrame,
                context: context,
                primaryTopY: primaryTopY,
                pid: pid,
                animKey: animKey,
                isAnimationLeaseActive: isAnimationLeaseActive,
                finishActive: finishActive,
                completion: completion
            )
        }

        if alreadyAtTileOrigin {
            runPhaseB()
            return .started
        }

        // 执行阶段 A：以当前尺寸滑到平铺目标原点（左上角锚定），完成后进入阶段 B 从该锚点放大。
        var phaseATimerBox: DispatchSourceTimer?
        phaseATimerBox = WindowAnimator.animate(
            from: CGRect(origin: currentPosition, size: windowSize),
            to: CGRect(origin: tileOriginAXForCurrentSize, size: windowSize),
            writer: { [weak self] frame in
                guard let self else { return false }
                guard self.animationSlot.activeLease == animationLease else { return false }
                if self.setPointAttribute(kAXPositionAttribute as CFString, value: frame.origin, on: windowElement) {
                    return true
                }
                return self.setRectAttribute("AXFrame" as CFString, value: frame, on: windowElement)
            },
            reader: reader,
            completion: { [weak self] outcome in
                // Phase-A 任一驱动终态都先移除 timer；只有 `.finished` 才进入 Phase-B。
                if let timer = phaseATimerBox {
                    self?.activeAnimatorTimers.removeAll { $0 === timer }
                }
                guard isAnimationLeaseActive() else {
                    DiagnosticLog.debug("tile-animator: ignored stale Phase-A completion pid=\(pid.map(String.init) ?? "?")")
                    return
                }
                if TilePhaseAOutcomePolicy.shouldEnterPhaseB(after: outcome) {
                    DiagnosticLog.debug("tile-animator: phase A done pid=\(pid.map(String.init) ?? "?")")
                    runPhaseB()
                } else {
                    DiagnosticLog.debug("tile-animator: phase A stopped outcome=\(outcome) pid=\(pid.map(String.init) ?? "?")")
                    finishActive()
                    completion?(outcome)
                }
            }
        )
        if let phaseATimer = phaseATimerBox {
            activeAnimatorTimers.append(phaseATimer)
        }
        return .started
    }

    /// Compatibility bridge for existing success-only call sites while they migrate to the typed
    /// completion overload above. Failure/interruption outcomes deliberately do not invoke the
    /// legacy callback, so they can never be mistaken for a completed layout.
    @discardableResult
    func tileWindowElementAnimated(
        _ windowElement: AXUIElement,
        pid: pid_t? = nil,
        appElement: AXUIElement? = nil,
        insets: TileInsets,
        completion: @escaping () -> Void
    ) throws -> WindowAnimationStartResult {
        try tileWindowElementAnimated(
            windowElement,
            pid: pid,
            appElement: appElement,
            insets: insets
        ) { outcome in
            guard outcome == .finished else { return }
            completion()
        }
    }

    // MARK: - Phase-B 丝滑放大 / 稳健降级

    /// 丝滑放大（默认）：60Hz × ease-out 帧驱动尺寸放大，左上角锚定向右下扩展。每帧读回实际尺寸
    /// 做弹回检测；若连续帧落后写入值超阈值，降级到 `runPhaseBRobust`（稳健大步）兜底。
    /// 末帧强制 pos+size 落地、读回重居中，逻辑与稳健模式完全一致（保持终端类 app grid snap 兼容）。
    private func runPhaseBSmooth(
        windowElement: AXUIElement,
        startSize: CGSize,
        endSize: CGSize,
        targetAXOrigin: CGPoint,
        targetFrame: CGRect,
        visibleFrame: CGRect,
        context: WindowContext,
        primaryTopY: CGFloat,
        pid: pid_t?,
        animKey: String,
        isAnimationLeaseActive: @escaping () -> Bool,
        finishActive: @escaping () -> Void,
        completion: WindowAnimator.Completion?
    ) {
        guard isAnimationLeaseActive() else { return }
        // 若起止尺寸几乎相同，无需放大，直接落地收尾。
        if abs(startSize.width - endSize.width) < 1 && abs(startSize.height - endSize.height) < 1 {
            finalizePhaseB(
                windowElement: windowElement,
                endSize: endSize,
                targetAXOrigin: targetAXOrigin,
                targetFrame: targetFrame,
                visibleFrame: visibleFrame,
                context: context,
                primaryTopY: primaryTopY,
                pid: pid,
                animKey: animKey,
                via: "smooth-noop",
                isAnimationLeaseActive: isAnimationLeaseActive,
                finishActive: finishActive,
                completion: completion
            )
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        activeTileTimer = timer
        let intervalNs: Int = 1_000_000_000 / max(1, Self.smoothPhaseBTickHz)
        timer.schedule(deadline: .now() + .milliseconds(Self.smoothPhaseBLeadInMs), repeating: .nanoseconds(intervalNs))
        let startTime = DispatchTime.now()
        var bounceTicks = 0
        timer.setEventHandler { [weak self] in
            guard let self else {
                timer.cancel()
                return
            }
            guard isAnimationLeaseActive() else {
                timer.cancel()
                return
            }
            // 前台守卫：若该 pid 已不是前台 app，立即停止——消除 zombie 定时器移动非前台窗口。
            if let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                timer.cancel()
                if self.activeTileTimer === timer { self.activeTileTimer = nil }
                finishActive()
                DiagnosticLog.debug("tile-animator: phase B aborted (pid=\(pid) no longer frontmost)")
                return
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
            let rawProgress = CGFloat(elapsed) / CGFloat(TimeInterval(Self.smoothPhaseBDuration) * 1_000_000_000)

            // 末帧：强制落地收尾。
            if rawProgress >= 1.0 {
                timer.cancel()
                if self.activeTileTimer === timer { self.activeTileTimer = nil }
                self.finalizePhaseB(
                    windowElement: windowElement,
                    endSize: endSize,
                    targetAXOrigin: targetAXOrigin,
                    targetFrame: targetFrame,
                    visibleFrame: visibleFrame,
                    context: context,
                    primaryTopY: primaryTopY,
                    pid: pid,
                    animKey: animKey,
                    via: "smooth",
                    isAnimationLeaseActive: isAnimationLeaseActive,
                    finishActive: finishActive,
                    completion: completion
                )
                return
            }

            // ease-out 插值尺寸（origin 不动，仅 width/height）。
            let p = WindowAnimator.easeOut(rawProgress)
            let curSize = CGSize(
                width: startSize.width + (endSize.width - startSize.width) * p,
                height: startSize.height + (endSize.height - startSize.height) * p
            )
            _ = self.resizeWindowWithFallback(windowElement, newSize: curSize)

            // 弹回检测：读回实际尺寸，若在任一轴上落后写入值超阈值，计为一帧弹回。
            // 仅在接近末段（progress > smoothPhaseBBounceBackMinProgress，默认 0.6）后才计弹回：
            // 前段 app 实际尺寸因 AX 异步延迟天然落后写入值 24~40px，这是物理正常的 lag 而非真弹回，
            // 旧实现用 0.25 门 + 24px 阈值会把这些正常 lag 误判为弹回并降级，破坏放大达成（首次不平铺根因）。
            if let actual = self.sizeAttribute(kAXSizeAttribute as CFString, on: windowElement) {
                let lagW = abs(actual.width - curSize.width)
                let lagH = abs(actual.height - curSize.height)
                if p > Self.smoothPhaseBBounceBackMinProgress && (lagW > Self.smoothPhaseBBounceBackPx || lagH > Self.smoothPhaseBBounceBackPx) {
                    bounceTicks += 1
                    DiagnosticLog.debug("tile-animator: bounce-back detected (tick=\(bounceTicks) lagW=\(lagW) lagH=\(lagH) written=\(curSize) actual=\(actual))")
                    if bounceTicks >= Self.smoothPhaseBBounceBackConsecutiveTicks {
                        // 降级到稳健大步模式。从【当前实际尺寸】接力（而非原始 startSize），
                        // 并跳过 lead-in（已在放大中，无需再 settle）——避免降级后从零重启 + 250ms 空档。
                        timer.cancel()
                        if self.activeTileTimer === timer { self.activeTileTimer = nil }
                        DiagnosticLog.debug("tile-animator: smooth -> robust fallback (pid=\(pid.map(String.init) ?? "?")) resume from \(actual)")
                        self.runPhaseBRobust(
                            windowElement: windowElement,
                            startSize: actual,
                            endSize: endSize,
                            targetAXOrigin: targetAXOrigin,
                            targetFrame: targetFrame,
                            visibleFrame: visibleFrame,
                            context: context,
                            primaryTopY: primaryTopY,
                            pid: pid,
                            animKey: animKey,
                            skipLeadIn: true,
                            isAnimationLeaseActive: isAnimationLeaseActive,
                            finishActive: finishActive,
                            completion: completion
                        )
                        return
                    }
                } else {
                    bounceTicks = 0
                }
            }
        }
        timer.resume()
    }

    /// 稳健大步放大（降级路径）：从 startSize 线性到 endSize，分 tilePhaseBSteps 步、每步 settle
    ///（tilePhaseBStepIntervalMs），是历史上验证过“绝不弹回”的方案。逻辑与重构前的原 Phase-B 完全一致。
    /// - Parameter skipLeadIn: 从丝滑模式接力降级时传 true——已在放大中，无需 tilePhaseBLeadInMs 的
    ///   settle 空档；直接开始分步。首次进入（非降级）传 false，保留 settle 防线。
    private func runPhaseBRobust(
        windowElement: AXUIElement,
        startSize: CGSize,
        endSize: CGSize,
        targetAXOrigin: CGPoint,
        targetFrame: CGRect,
        visibleFrame: CGRect,
        context: WindowContext,
        primaryTopY: CGFloat,
        pid: pid_t?,
        animKey: String,
        skipLeadIn: Bool = false,
        isAnimationLeaseActive: @escaping () -> Bool,
        finishActive: @escaping () -> Void,
        completion: WindowAnimator.Completion?
    ) {
        guard isAnimationLeaseActive() else { return }
        let steps = Self.tilePhaseBSteps
        let timer = DispatchSource.makeTimerSource(queue: .main)
        activeTileTimer = timer
        var step = 0
        let leadInMs = skipLeadIn ? 0 : Self.tilePhaseBLeadInMs
        timer.schedule(deadline: .now() + .milliseconds(leadInMs), repeating: .milliseconds(Self.tilePhaseBStepIntervalMs))
        timer.setEventHandler { [weak self] in
            guard let self else {
                timer.cancel()
                return
            }
            guard isAnimationLeaseActive() else {
                timer.cancel()
                return
            }
            // 前台守卫：若该 pid 已不是前台 app，立即停止——这是消除"切走后 Safari
            // 被 zombie 定时器拉到另一屏"的关键防线（即便外部未调用 abort）。
            if let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                timer.cancel()
                if self.activeTileTimer === timer { self.activeTileTimer = nil }
                finishActive()
                DiagnosticLog.debug("tile-animator: phase B aborted (pid=\(pid) no longer frontmost)")
                return
            }
            step += 1
            if step >= steps {
                timer.cancel()
                if self.activeTileTimer === timer { self.activeTileTimer = nil }
                self.finalizePhaseB(
                    windowElement: windowElement,
                    endSize: endSize,
                    targetAXOrigin: targetAXOrigin,
                    targetFrame: targetFrame,
                    visibleFrame: visibleFrame,
                    context: context,
                    primaryTopY: primaryTopY,
                    pid: pid,
                    animKey: animKey,
                    via: "robust",
                    isAnimationLeaseActive: isAnimationLeaseActive,
                    finishActive: finishActive,
                    completion: completion
                )
                return
            }
            let p = CGFloat(step) / CGFloat(steps)
            let curW = startSize.width + (endSize.width - startSize.width) * p
            let curH = startSize.height + (endSize.height - startSize.height) * p
            let curSize = CGSize(width: curW, height: curH)
            _ = self.resizeWindowWithFallback(windowElement, newSize: curSize)
        }
        timer.resume()
    }

    /// Phase-B 收尾（丝滑与稳健共用）：强制 pos+size 落地、读回实际尺寸、必要时 settle-and-recheck、清锁。
    ///
    /// 尺寸已达成（差 ≤4px）：走快速路径，立即锚定+清锁。
    /// 尺寸未达成：两种可能——(a) app 真有硬上限（终端按字符网格 snap）；(b) 重型 app（Pages 新建文稿）
    /// 的 layout 滞后于 60Hz 写入，读回的是未追平的旧尺寸。两者无法在收尾瞬间区分，故统一走
    /// `scheduleSettleAndAnchor`：保持动画锁、多轮重写+重读，给 layout 追平时间。settle 后仍达不到
    /// 才视为真硬限，走 top-left 锚定接受实际尺寸。
    private func finalizePhaseB(
        windowElement: AXUIElement,
        endSize: CGSize,
        targetAXOrigin: CGPoint,
        targetFrame: CGRect,
        visibleFrame: CGRect,
        context: WindowContext,
        primaryTopY: CGFloat,
        pid: pid_t?,
        animKey: String?,
        via: String,
        isAnimationLeaseActive: @escaping () -> Bool,
        finishActive: @escaping () -> Void,
        completion: WindowAnimator.Completion?
    ) {
        guard isAnimationLeaseActive() else { return }
        // 最终强制 pos+size 落到目标。
        _ = setPointAttribute(kAXPositionAttribute as CFString, value: targetAXOrigin, on: windowElement)
        let sizeOutcome = resizeWindowWithFallback(windowElement, newSize: endSize)
        // 读回实际尺寸。若与目标差异较大，可能是 app layout 滞后（Pages 60Hz 写入下回读恒为旧值）。
        let actualSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        if let actualSize, (abs(actualSize.width - endSize.width) > 4 || abs(actualSize.height - endSize.height) > 4) {
            // 尺寸未达成：保持动画锁，settle-and-recheck。finishActive/completion 延后到 settle 内调用。
            DiagnosticLog.debug("tile-animator: phase B size not reached via=\(via) actual=\(actualSize) target=\(endSize) — scheduling settle")
            scheduleSettleAndAnchor(
                windowElement: windowElement,
                endSize: endSize,
                targetAXOrigin: targetAXOrigin,
                targetFrame: targetFrame,
                context: context,
                primaryTopY: primaryTopY,
                pid: pid,
                animKey: animKey,
                via: via,
                firstOutcome: sizeOutcome,
                isAnimationLeaseActive: isAnimationLeaseActive,
                finishActive: finishActive,
                completion: completion
            )
            return
        }
        // 尺寸已达成（或读不到）：走快速收尾，立即锚定+清锁。
        emitFinalAnchor(
            windowElement: windowElement,
            endSize: endSize,
            targetAXOrigin: targetAXOrigin,
            targetFrame: targetFrame,
            context: context,
            primaryTopY: primaryTopY,
            pid: pid,
            via: via,
            sizeOutcome: sizeOutcome,
            isAnimationLeaseActive: isAnimationLeaseActive,
            finishActive: finishActive,
            completion: completion
        )
    }

    /// settle-and-recheck：动画收尾时尺寸未达成（重型 app layout 滞后），保持动画锁、多轮重写+重读。
    ///
    /// 复用 activeTileTimer 通道（`stop()`、前台守卫已覆盖其生命周期）。最多 `settleMaxRounds` 轮，
    /// 每轮间隔 `settleDelayMs`：重写 pos+size → 读回 → 达成或到上限即终止。保持动画锁到 settle
    /// 结束，顺带挡住 app layout-settling 期间到达的 move/resize 通知被误判为「用户拖动」而标记 manual。
    private func scheduleSettleAndAnchor(
        windowElement: AXUIElement,
        endSize: CGSize,
        targetAXOrigin: CGPoint,
        targetFrame: CGRect,
        context: WindowContext,
        primaryTopY: CGFloat,
        pid: pid_t?,
        animKey: String?,
        via: String,
        firstOutcome: ResizeOutcome,
        isAnimationLeaseActive: @escaping () -> Bool,
        finishActive: @escaping () -> Void,
        completion: WindowAnimator.Completion?
    ) {
        guard isAnimationLeaseActive() else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        activeTileTimer = timer
        var round = 0
        timer.schedule(deadline: .now() + .milliseconds(Self.settleDelayMs), repeating: .milliseconds(Self.settleDelayMs))
        timer.setEventHandler { [weak self] in
            guard let self else {
                timer.cancel()
                return
            }
            guard isAnimationLeaseActive() else {
                timer.cancel()
                return
            }
            // 前台守卫（与 runPhaseBSmooth/Robust 一致）：切走即终止。activation teardown
            // 会取消上层 coordinator；这里不能继续写后台窗口，也不能伪报 `.finished`。
            if let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                timer.cancel()
                if self.activeTileTimer === timer { self.activeTileTimer = nil }
                DiagnosticLog.debug("tile-animator: settle aborted (pid=\(pid) no longer frontmost)")
                finishActive()
                return
            }
            round += 1
            // 重写 pos+size（pos 也重写，防 layout 滚动期间 origin 漂）。
            _ = self.setPointAttribute(kAXPositionAttribute as CFString, value: targetAXOrigin, on: windowElement)
            let outcome = self.resizeWindowWithFallback(windowElement, newSize: endSize)
            let now = self.sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
            // 见好就收：尺寸达标 **或** 统一判定通过（含妥协形态）。后者覆盖 Numbers 忙碌期
            // 把高度读回比目标略大但已保底锚定（妥协形态）的情形——settle 不必非等到尺寸精确，
            // 避免「明明已落到可接受的妥协形态仍继续重写」的徒劳轮次。
            let sizeReached = now.map { abs($0.width - endSize.width) <= 4 && abs($0.height - endSize.height) <= 4 } ?? false
            let frameReached = self.currentGlobalFrame(windowElement, context: context, primaryTopY: primaryTopY)
                .map { self.frameSatisfiesFinalTiledTarget($0, target: targetFrame) } ?? false
            let reached = sizeReached || frameReached
            DiagnosticLog.debug("tile-animator: settle round=\(round)/\(Self.settleMaxRounds) via=\(via) wrote=\(endSize) read=\(now.map { String(describing: $0) } ?? "nil") sizeReached=\(sizeReached) frameReached=\(frameReached)")
            if reached || round >= Self.settleMaxRounds {
                timer.cancel()
                if self.activeTileTimer === timer { self.activeTileTimer = nil }
                self.emitFinalAnchor(
                    windowElement: windowElement,
                    endSize: endSize,
                    targetAXOrigin: targetAXOrigin,
                    targetFrame: targetFrame,
                    context: context,
                    primaryTopY: primaryTopY,
                    pid: pid,
                    via: reached ? "\(via)+settle" : "\(via)+settle-giveup",
                    sizeOutcome: outcome,
                    isAnimationLeaseActive: isAnimationLeaseActive,
                    finishActive: finishActive,
                    completion: completion
                )
            }
            // 未达成且未到上限：下一轮（重复定时器自动触发）。
        }
        timer.resume()
    }

    /// 最终锚定 + 清锁收尾（快速路径与 settle 路径共用，保证两条路径的锚定语义完全一致）。
    ///
    /// 两条分支：
    /// - **尺寸对、位置漂**（posOff-only，iWork resize 漂 origin）：写一次 `targetAXOrigin` 收尾。
    /// - **尺寸偏差**（sizeOff，app 拒缩放 / 载入忙碌期竞态）：启动「精确目标重写链」——
    ///   用退避定时器（250ms / 500ms / 1000ms）等待 app 忙碌期结束，每轮**只写目标尺寸 `endSize`**
    ///   再按读回的实际尺寸锚位置（保顶或保底的妥协形态），3 次后无条件收尾。
    ///
    /// 关键：**位置写入永远用刚读回的实际高度换算**，绝不用「假设高度」——否则会把实际更高的
    /// 窗口底边推到屏幕外（旧 shrink 阶梯的出屏 bug）。app 抢的是尺寸、从不抗拒位置写入，
    /// 所以即使 3 次重写都没把尺寸写到 `endSize`，最后一次按实际尺寸的妥协锚定也能保证
    /// 「顶距或底距之一严格等于设置值」（妥协形态与 `expectedFallbackFrame` 同源，判定必然接受）。
    private func emitFinalAnchor(
        windowElement: AXUIElement,
        endSize: CGSize,
        targetAXOrigin: CGPoint,
        targetFrame: CGRect,
        context: WindowContext,
        primaryTopY: CGFloat,
        pid: pid_t?,
        via: String,
        sizeOutcome: ResizeOutcome,
        isAnimationLeaseActive: @escaping () -> Bool,
        finishActive: @escaping () -> Void,
        completion: WindowAnimator.Completion?
    ) {
        guard isAnimationLeaseActive() else { return }
        let actualSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        let actualPos = pointAttribute(kAXPositionAttribute as CFString, on: windowElement)
        // 尺寸偏差（app 拒绝缩放 / Numbers 载入忙碌期竞态 / Pages layout 滞后）。
        let sizeOff = actualSize.map { abs($0.width - endSize.width) > 4 || abs($0.height - endSize.height) > 4 } ?? false
        // 位置漂移：iWork（Numbers/Pages）在 60Hz 小步 kAXSize 写入（smooth Phase B）期间会让 origin 漂移
        // （实测 Numbers x: 16→25），即便尺寸已达成。Terminal 等不漂的 app 此处为 false（no-op）。
        let posOff = actualPos.map { abs($0.x - targetAXOrigin.x) > 2 || abs($0.y - targetAXOrigin.y) > 2 } ?? false

        // 尺寸偏差：启动精确目标重写链（替代旧的贴底收缩阶梯）。
        // 旧阶梯把失败建模成「app 有硬性高度上限需要下探」，但真实机制是载入忙碌期的写入竞态——
        // 下探矮高度不解决竞态，只决定哪个错误高度胜出（顶距翻倍 bug）。改为只写目标尺寸 + 等时机。
        if sizeOff {
            runPreciseTargetRewriteChain(
                windowElement: windowElement,
                endSize: endSize,
                targetAXOrigin: targetAXOrigin,
                targetFrame: targetFrame,
                context: context,
                primaryTopY: primaryTopY,
                pid: pid,
                via: via,
                sizeOutcome: sizeOutcome,
                attemptIndex: 0,
                isAnimationLeaseActive: isAnimationLeaseActive,
                finishActive: finishActive,
                completion: completion
            )
            return
        }

        // 尺寸已对、仅位置漂：写一次 targetAXOrigin 收尾。
        if posOff {
            let alreadySatisfiesTarget = currentGlobalFrame(
                windowElement,
                context: context,
                primaryTopY: primaryTopY
            ).map { frameSatisfiesFinalTiledTarget($0, target: targetFrame) } ?? false
            if !alreadySatisfiesTarget {
                _ = setPointAttribute(kAXPositionAttribute as CFString, value: targetAXOrigin, on: windowElement)
                DiagnosticLog.debug("tile-animator: anchored drift (posOff) actualPos=\(actualPos.map { String(describing: $0) } ?? "nil") → \(targetAXOrigin) targetAX=\(targetAXOrigin)")
            }
        }
        finishEmitFinalAnchor(
            windowElement: windowElement,
            targetFrame: targetFrame,
            targetAXOrigin: targetAXOrigin,
            context: context,
            primaryTopY: primaryTopY,
            pid: pid,
            via: via,
            sizeOutcome: sizeOutcome,
            isAnimationLeaseActive: isAnimationLeaseActive,
            finishActive: finishActive,
            completion: completion
        )
    }

    /// 精确目标重写链：尺寸偏差时用退避定时器等待 app 忙碌期结束，每轮只写目标尺寸 + 按实际尺寸锚位置。
    ///
    /// 至多 3 次，退避 250ms / 500ms / 1000ms（实测 Numbers 忙碌期从窗口出现算约 3.1s，走到
    /// emitFinalAnchor 时已消耗 ~2.6s，此参数覆盖尾部并留裕量）。定时器走 `activeTileTimer` 受追踪
    /// 通道（`stop()` / `abortActiveAnimations()` 能取消），每次触发先做前台守卫（切走即收尾退出，
    /// 不写后台窗口）。3 次全失败后的终末步：再执行一次位置锚定（用实际尺寸的妥协形态）然后无条件收尾。
    private func runPreciseTargetRewriteChain(
        windowElement: AXUIElement,
        endSize: CGSize,
        targetAXOrigin: CGPoint,
        targetFrame: CGRect,
        context: WindowContext,
        primaryTopY: CGFloat,
        pid: pid_t?,
        via: String,
        sizeOutcome: ResizeOutcome,
        attemptIndex: Int,
        isAnimationLeaseActive: @escaping () -> Bool,
        finishActive: @escaping () -> Void,
        completion: WindowAnimator.Completion?
    ) {
        guard isAnimationLeaseActive() else { return }
        let backoffsMs: [Int] = [250, 500, 1000]
        let isFinalAttempt = attemptIndex >= backoffsMs.count - 1
        let delayMs = backoffsMs[min(attemptIndex, backoffsMs.count - 1)]
        DiagnosticLog.debug("tile-animator: precise-rewrite attempt \(attemptIndex + 1)/\(backoffsMs.count) pid=\(pid.map(String.init) ?? "?") delay=\(delayMs)ms endSize=\(endSize) target=\(targetFrame)")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        activeTileTimer = timer
        timer.schedule(deadline: .now() + .milliseconds(delayMs))
        timer.setEventHandler { [weak self] in
            guard let self else {
                // Service teardown owns cancellation. Object disappearance is not a
                // successful geometry terminal and must never be reported as one.
                timer.cancel()
                return
            }
            guard isAnimationLeaseActive() else {
                timer.cancel()
                return
            }
            if self.activeTileTimer === timer { self.activeTileTimer = nil }

            // 前台守卫：切走即收尾退出（不写后台窗口），与 Phase-B settle/smooth/robust 一致。
            if let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                DiagnosticLog.debug("tile-animator: precise-rewrite aborted (pid=\(pid) no longer frontmost)")
                finishActive()
                return
            }

            // 写入顺序（关键，防「假设高度出屏」bug 复发）：
            // 1. 永远只写目标尺寸 endSize，绝不写其它高度（旧阶梯写矮高度 → 顶距翻倍）。
            _ = self.resizeWindowWithFallback(windowElement, newSize: endSize)
            // 2. 读回实际尺寸。
            let actual = self.sizeAttribute(kAXSizeAttribute as CFString, on: windowElement) ?? endSize
            // 3. 尺寸达标 → 写目标 origin；否则用实际尺寸算妥协 origin（保顶 / 保底）。
            let sizeReached = abs(actual.width - endSize.width) <= 4 && abs(actual.height - endSize.height) <= 4
            let anchoredBL = sizeReached
                ? targetFrame.origin
                : WindowGeometry.constrainedTileFallbackOrigin(targetFrame: targetFrame, actualSize: actual)
            // 位置写入使用的高度必须是刚读回的实际高度（否则会把更高窗口的底边推到屏外）。
            let anchoredAX = self.toAXOrigin(
                bottomLeftOrigin: anchoredBL,
                windowSize: actual,
                screenFrame: context.screen.frame,
                space: context.space,
                primaryTopY: primaryTopY
            )
            _ = self.setPointAttribute(kAXPositionAttribute as CFString, value: anchoredAX, on: windowElement)

            // 4. 读回解算后的 global frame，统一判定通过 → 收尾。
            let postFrame = self.currentGlobalFrame(windowElement, context: context, primaryTopY: primaryTopY)
            let satisfied = postFrame.map { self.frameSatisfiesFinalTiledTarget($0, target: targetFrame) } ?? false
            DiagnosticLog.debug("tile-animator: precise-rewrite check \(attemptIndex + 1)/\(backoffsMs.count) actual=\(actual) sizeReached=\(sizeReached) postFrame=\(postFrame.map { String(describing: $0) } ?? "nil") satisfied=\(satisfied)")

            if satisfied || isFinalAttempt {
                self.finishEmitFinalAnchor(
                    windowElement: windowElement,
                    targetFrame: targetFrame,
                    targetAXOrigin: targetAXOrigin,
                    context: context,
                    primaryTopY: primaryTopY,
                    pid: pid,
                    via: satisfied ? "\(via)+precise" : "\(via)+precise-giveup",
                    sizeOutcome: sizeOutcome,
                    isAnimationLeaseActive: isAnimationLeaseActive,
                    finishActive: finishActive,
                    completion: completion
                )
            } else {
                self.runPreciseTargetRewriteChain(
                    windowElement: windowElement,
                    endSize: endSize,
                    targetAXOrigin: targetAXOrigin,
                    targetFrame: targetFrame,
                    context: context,
                    primaryTopY: primaryTopY,
                    pid: pid,
                    via: via,
                    sizeOutcome: sizeOutcome,
                    attemptIndex: attemptIndex + 1,
                    isAnimationLeaseActive: isAnimationLeaseActive,
                    finishActive: finishActive,
                    completion: completion
                )
            }
        }
        timer.resume()
    }

    /// emitFinalAnchor 的统一收尾：读最终 frame，打取证日志（含 finalFrame vs target + satisfied），
    /// 清动画锁、回调 completion。成功执行链（posOnly / precise-rewrite）都经此收尾，
    /// lifecycle abort 不进入此方法，也不产生伪 `.finished`，
    /// 保证 phase B done 日志行格式一致、四向边距可取证。
    private func finishEmitFinalAnchor(
        windowElement: AXUIElement,
        targetFrame: CGRect,
        targetAXOrigin: CGPoint,
        context: WindowContext,
        primaryTopY: CGFloat,
        pid: pid_t?,
        via: String,
        sizeOutcome: ResizeOutcome,
        isAnimationLeaseActive: @escaping () -> Bool,
        finishActive: @escaping () -> Void,
        completion: WindowAnimator.Completion?
    ) {
        guard isAnimationLeaseActive() else {
            DiagnosticLog.debug("tile-animator: ignored stale finalization pid=\(pid.map(String.init) ?? "?")")
            return
        }
        let postSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        let postPos = pointAttribute(kAXPositionAttribute as CFString, on: windowElement)
        let finalFrame = currentGlobalFrame(windowElement, context: context, primaryTopY: primaryTopY)
        let satisfied = finalFrame.map { frameSatisfiesFinalTiledTarget($0, target: targetFrame) } ?? false
        DiagnosticLog.debug("tile-animator: phase B done (via=\(via)) pid=\(pid.map(String.init) ?? "?") target=\(targetFrame) targetAX=\(targetAXOrigin) via=\(sizeOutcome) actualPos=\(postPos.map { String(describing: $0) } ?? "nil") actualSize=\(postSize.map { String(describing: $0) } ?? "nil") finalFrame=\(finalFrame.map { String(describing: $0) } ?? "nil") satisfied=\(satisfied)")
        finishActive()
        completion?(.finished)
    }

    private func currentGlobalFrame(
        _ windowElement: AXUIElement,
        context: WindowContext,
        primaryTopY: CGFloat
    ) -> CGRect? {
        guard
            let rawPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let rawSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else { return nil }
        return rawToGlobalRect(
            space: context.space,
            screenFrame: context.screen.frame,
            rawPosition: rawPosition,
            windowSize: rawSize,
            primaryTopY: primaryTopY
        )
    }

    // MARK: - 共享解算 / 动画辅助

    /// 只读查询：返回给定窗口在当前屏幕上的平铺目标 frame（`visibleFrame` 内缩四向 insets）。
    /// 复用与平铺动画相同的坐标空间探测与 `WindowGeometry.tiledFrame` 计算，但不写任何 AX 属性、
    /// 也不启动动画。供 `WindowEventObserver.isWindowNearTiledTarget` 判断"窗口是否已铺满、
    /// 可停止重试"使用——替换此前无法访问内部接口时的粗略面积启发式。
    /// 读取失败或无法确定坐标空间时返回 nil。
    func tiledTargetFrame(for windowElement: AXUIElement, pid: pid_t?, insets: TileInsets) -> CGRect? {
        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            return nil
        }
        let primaryTopY = primaryScreenTopY()
        // 优先 CG 信号（需 pid 以匹配 CGWindowList 的 ownerPID），回退 AX 推断；与平铺路径一致。
        if let pid {
            if let cgContext = detectWindowContextUsingCG(
                windowElement: windowElement,
                pid: pid,
                rawPosition: currentPosition,
                windowSize: windowSize,
                primaryTopY: primaryTopY
            ) {
                let visibleFrame = effectiveVisibleFrame(for: cgContext.screen)
                return WindowGeometry.tiledFrame(visibleFrame: visibleFrame, insets: insets)
            }
        }
        guard let context = detectWindowContext(
            rawPosition: currentPosition,
            windowSize: windowSize,
            pid: pid,
            primaryTopY: primaryTopY
        ) else { return nil }
        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        return WindowGeometry.tiledFrame(visibleFrame: visibleFrame, insets: insets)
    }

    /// 只读查询：窗口当前 frame（minX/minY/width/height）是否已完整匹配平铺目标。
    ///
    /// 复用与平铺路径相同的坐标空间探测（4 种空间 + CG 信号），并比较**全部四个维度**
    /// （不只 size）——这是与 `tiledTargetFrame` 配套的「在位校验」：`tiledTargetFrame`
    /// 只返回目标 frame，调用方需自行比较；本方法封装「解算目标 + 读窗口 + 比对」整段。
    ///
    /// ⚠️ 完成判定统一走 `frameSatisfiesFinalTiledTarget`（逐边语义判定，详见
    /// `WindowGeometry.frameMatchesTiledTarget` 的容差策略）：
    ///   - 左边严格 3px、底边向内宽松 16px、**顶边 ±6px（关键：挡住「贴底短高」吃顶距）**、
    ///     右边 −16/+6px；外加「等于妥协形态」「3px 内完整覆盖」两条兜底。
    ///   - 左边严格挡住 iWork（Numbers/Pages）在 smooth Phase B resize 后的 origin 漂移
    ///     （实测 x: 16→25，漂移 9px），避免锁在漂移位置上。
    ///   - 底/右向内宽松保留对 Terminal/electerm 按字符网格 snap 尺寸（偏差可达 10-20px）的 app
    ///     的兼容：它们的尺寸确实无法精确到位，但 origin 正确，应判定为完成并锁 PID。
    ///   - 顶边 ±6px 是本次修复的核心：旧「minY 严格 + height ≤16」判定放行了「贴底矮 16px」
    ///     形态（maxY 缺 16px → 顶距被吃掉），导致 Numbers 顶距翻倍 bug。
    ///
    /// 与 `tileReachedTarget` 共用坐标空间探测（同走 CG 优先 + AX 回退），判定语义完全一致。
    /// 读取失败或无法确定坐标空间时返回 false（保守地由调用方视为「未达目标」，继续重试）。
    func isWindowAtTiledTarget(
        _ windowElement: AXUIElement,
        pid: pid_t?,
        insets: TileInsets
    ) -> Bool {
        guard
            let rawPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else { return false }
        let primaryTopY = primaryScreenTopY()

        // CG 路径（需 Screen Recording 权限 + pid）：与 tileReachedTarget 的 CG 分支同构。
        // expectedSize 用当前 windowSize（仅在 AXWindowNumber 缺失时的 fallback 评分里用到）。
        if let pid,
           ScreenCapturePermission.ensureAuthorized(prompt: false),
           let cgRect = cgWindowBounds(
               windowID: windowIDAttribute(on: windowElement),
               pid: pid,
               expectedSize: windowSize,
               preferredDisplayID: nil
           ),
           let screenPick = pickScreenForCGRect(cgRect)
        {
            let cocoaRect = cocoaRectFromCGWindowBounds(cgRect, screen: screenPick.screen, primaryTopY: primaryTopY)
            let visibleFrame = effectiveVisibleFrame(for: screenPick.screen)
            let targetFrame = WindowGeometry.tiledFrame(visibleFrame: visibleFrame, insets: insets)
            // origin 严格 / size 宽松（详见方法注释）：挡住 iWork origin 漂移，兼容 size snap。
            if frameSatisfiesFinalTiledTarget(cocoaRect, target: targetFrame) {
                return true
            }
            DiagnosticLog.debug("isWindowAtTiledTarget: CG mismatch, falling back to AX pid=\(pid) cgRect=\(cgRect) target=\(targetFrame)")
        }

        // AX 回退路径：探测坐标空间 → 取 context.currentGlobalRect → 比 frame。
        guard let context = detectWindowContext(
            rawPosition: rawPosition,
            windowSize: windowSize,
            pid: pid,
            primaryTopY: primaryTopY
        ) else { return false }
        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let targetFrame = WindowGeometry.tiledFrame(visibleFrame: visibleFrame, insets: insets)
        return frameSatisfiesFinalTiledTarget(context.currentGlobalRect, target: targetFrame)
    }

    /// 预算耗尽锁定前的最后修正（无动画、无定时器、单次写入）。
    ///
    /// 读实际 frame，若未满足统一判定，按 `constrainedTileFallbackOrigin`（矮窗保顶 / 高窗保底）
    /// **只写一次 position**。位置写入 app 从不抗拒（Numbers 抢的是尺寸），保证锁定结局
    /// 「顶距或底距之一严格等于设置值」，不再出现「贴底短高、缺口全堆到顶部」被锁定的形态。
    ///
    /// 若 `isAnyAnimationInProgress` 为真则直接返回（不与进行中的平铺会话打架——会话内部
    /// 已有自己的精确重写链做位置修正）。读取失败或无法确定坐标空间时返回（保守不动）。
    func anchorWindowToFallbackOrigin(_ windowElement: AXUIElement, pid: pid_t?, insets: TileInsets) {
        // 不与进行中的平铺会话打架：会话内部（emitFinalAnchor 的精确重写链）已做位置修正。
        guard !isAnyAnimationInProgress else { return }
        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else { return }
        let primaryTopY = primaryScreenTopY()

        // 坐标空间探测 + targetFrame 解算（与 tiledTargetFrame / isWindowAtTiledTarget 同款）。
        let context: WindowContext?
        if let pid, let cgContext = detectWindowContextUsingCG(
            windowElement: windowElement,
            pid: pid,
            rawPosition: currentPosition,
            windowSize: windowSize,
            primaryTopY: primaryTopY
        ) {
            context = cgContext
        } else {
            context = detectWindowContext(
                rawPosition: currentPosition,
                windowSize: windowSize,
                pid: pid,
                primaryTopY: primaryTopY
            )
        }
        guard let context else { return }
        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let targetFrame = WindowGeometry.tiledFrame(visibleFrame: visibleFrame, insets: insets)

        // 读实际 global frame，已满足统一判定则不动。
        guard let actualFrame = currentGlobalFrame(windowElement, context: context, primaryTopY: primaryTopY) else { return }
        if frameSatisfiesFinalTiledTarget(actualFrame, target: targetFrame) {
            DiagnosticLog.debug("anchor-fallback: already satisfied pid=\(pid.map(String.init) ?? "?") frame=\(actualFrame) target=\(targetFrame)")
            return
        }

        // 妥协锚定（矮窗保顶 / 高窗保底）+ 用实际尺寸换算 AX origin，只写一次 position。
        let anchoredBL = WindowGeometry.constrainedTileFallbackOrigin(targetFrame: targetFrame, actualSize: actualFrame.size)
        let anchoredAX = toAXOrigin(
            bottomLeftOrigin: anchoredBL,
            windowSize: actualFrame.size,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryTopY
        )
        _ = setPointAttribute(kAXPositionAttribute as CFString, value: anchoredAX, on: windowElement)
        DiagnosticLog.debug("anchor-fallback: corrected pid=\(pid.map(String.init) ?? "?") actualFrame=\(actualFrame) target=\(targetFrame) → bl=\(anchoredBL) ax=\(anchoredAX)")
    }


    /// 解算居中目标（坐标空间探测 + 居中原点 + AX 原点）。非动画与动画路径共用。
    private func resolveCenterTarget(windowElement: AXUIElement, pid: pid_t?) -> CenterTarget? {
        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            return nil
        }

        let primaryTopY = primaryScreenTopY()
        let context: WindowContext?
        if let pid, let cgContext = detectWindowContextUsingCG(windowElement: windowElement, pid: pid, rawPosition: currentPosition, windowSize: windowSize, primaryTopY: primaryTopY) {
            context = cgContext
        } else {
            context = detectWindowContext(rawPosition: currentPosition, windowSize: windowSize, pid: pid, primaryTopY: primaryTopY)
        }
        guard let context else { return nil }

        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let centeredBottomLeftOrigin = WindowGeometry.centeredOrigin(windowSize: windowSize, visibleFrame: visibleFrame)
        let targetAXOrigin = toAXOrigin(
            bottomLeftOrigin: centeredBottomLeftOrigin,
            windowSize: windowSize,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryTopY
        )
        DiagnosticLog.debug("resolveCenterTarget: pid=\(pid.map(String.init) ?? "?") rawPos=\(currentPosition) size=\(windowSize) visibleFrame=\(visibleFrame) space=\(context.space) centeredBL=\(centeredBottomLeftOrigin) targetAX=\(targetAXOrigin)")
        return CenterTarget(
            context: context,
            visibleFrame: visibleFrame,
            centeredBottomLeftOrigin: centeredBottomLeftOrigin,
            targetAXOrigin: targetAXOrigin
        )
    }

    /// 居中目标 AX origin（在窗口当前报告的坐标空间内），供 observer 做「是否已在位」校验。
    ///
    /// 复用 `resolveCenterTarget` 的坐标空间探测（4 种空间 + CG 信号），不写任何 AX 属性、
    /// 不启动动画。与 `tiledTargetFrame` 同构——后者供平铺在位校验（`isWindowNearTiledTarget`），
    /// 本方法供居中在位校验（observer 端 `isWindowNearCenterTarget`）。
    /// 读取失败或无法确定坐标空间时返回 nil（保守地视为「不在位」）。
    func centeredTargetAXOrigin(for windowElement: AXUIElement, pid: pid_t?) -> CGPoint? {
        resolveCenterTarget(windowElement: windowElement, pid: pid)?.targetAXOrigin
    }

    /// Read back the current AX origin and verify that a completed center animation really reached
    /// the same target the service would choose now. Setter success alone is not a completion signal:
    /// some applications accept the write and immediately restore their own frame.
    func isWindowAtCenteredTarget(
        _ windowElement: AXUIElement,
        pid: pid_t?,
        tolerance: CGFloat = 3
    ) -> Bool {
        guard
            let current = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let target = resolveCenterTarget(windowElement: windowElement, pid: pid)?.targetAXOrigin
        else {
            return false
        }
        return abs(current.x - target.x) <= tolerance && abs(current.y - target.y) <= tolerance
    }

    /// 是否可调整窗口大小。
    /// 探测顺序：先试 kAXSizeAttribute（标准窗口都走这条）；若失败再试 AXFrame
    /// （同时写 origin+size）。许多 Electron / Chromium 应用（如 Apifox）拒绝单独写
    /// kAXSize 但接受 AXFrame —— 旧实现只试 kAXSize，导致这类应用被判为"不可调整大小"，
    /// 平铺阶段 B 被跳过，窗口永远无法放大（用户反馈"平铺对 Apifox 无效"的根因之一）。
    private func isResizable(_ windowElement: AXUIElement) -> Bool {
        guard let current = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement) else {
            return false
        }
        if setSizeAttribute(kAXSizeAttribute as CFString, value: current, on: windowElement) {
            return true
        }
        // kAXSize 写不进：尝试用 AXFrame 写回当前 origin+size（需读 position）。
        if let pos = pointAttribute(kAXPositionAttribute as CFString, on: windowElement) {
            let frame = CGRect(origin: pos, size: current)
            return setRectAttribute("AXFrame" as CFString, value: frame, on: windowElement)
        }
        return false
    }

    /// 生成动画去重 key。
    private func animationKey(for windowElement: AXUIElement, pid: pid_t?, kind: String) -> String {
        let pidPart = pid.map { String($0) } ?? "?"
        if let num = windowIDAttribute(on: windowElement) {
            return "\(kind):\(pidPart):\(num)"
        }
        return "\(kind):\(pidPart):ax:\(CFHash(windowElement))"
    }

    private func focusedWindowElement(for appElement: AXUIElement) -> AXUIElement? {
        windowAttribute(kAXFocusedWindowAttribute as CFString, on: appElement)
    }

    private func mainWindowElement(for appElement: AXUIElement) -> AXUIElement? {
        windowAttribute(kAXMainWindowAttribute as CFString, on: appElement)
    }

    private func windowElements(for appElement: AXUIElement) -> [AXUIElement] {
        appElement.axWindowElements(kAXWindowsAttribute as CFString)
    }

    private func isApplicationInFullscreen(_ appElement: AXUIElement) -> Bool {
        // Prefer checking main/focused window to avoid scanning too many windows.
        if let main = mainWindowElement(for: appElement), isFullscreenWindow(main) {
            return true
        }
        if let focused = focusedWindowElement(for: appElement), isFullscreenWindow(focused) {
            return true
        }
        return false
    }

    private func selectCenterableWindow(
        focused: AXUIElement?,
        windows: [AXUIElement],
        selectionPolicy: WindowSelectionPolicy
    ) -> AXUIElement? {
        if let focused, !isFullscreenWindow(focused) {
            return focused
        }
        if selectionPolicy == .focusedOnly {
            return nil
        }
        return windows.first(where: { !isFullscreenWindow($0) })
    }

    private func windowAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        // 委托给共享 AXAttributeAccess 扩展（带 CFGetTypeID 防御，行为与旧实现一致）。
        element.axWindowElement(attribute)
    }

    private func pointAttribute(_ attribute: CFString, on element: AXUIElement) -> CGPoint? {
        element.axPoint(attribute)
    }

    private func sizeAttribute(_ attribute: CFString, on element: AXUIElement) -> CGSize? {
        element.axSize(attribute)
    }

    private func setPointAttribute(_ attribute: CFString, value: CGPoint, on element: AXUIElement) -> Bool {
        var mutablePoint = value
        guard let axValue = AXValueCreate(.cgPoint, &mutablePoint) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, attribute, axValue) == .success
    }

    private func setSizeAttribute(_ attribute: CFString, value: CGSize, on element: AXUIElement) -> Bool {
        var mutableSize = value
        guard let axValue = AXValueCreate(.cgSize, &mutableSize) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, attribute, axValue) == .success
    }

    private func setRectAttribute(_ attribute: CFString, value: CGRect, on element: AXUIElement) -> Bool {
        var mutableRect = value
        guard let axValue = AXValueCreate(.cgRect, &mutableRect) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, attribute, axValue) == .success
    }

    /// 设置窗口尺寸，先试 kAXSizeAttribute；写不进（Electron/Chromium 类应用，如 SiYuan、Apifox）
    /// 时读取当前 origin 并用 AXFrame 写回 (currentOrigin, newSize)。
    ///
    /// 这是平铺阶段 B（以及同步 tileWindowElement）能放大 Electron 应用窗口的关键——这类应用
    /// 拒绝单独写 kAXSize 但接受 AXFrame（与 Phase A 居中时的 AXFrame fallback 行为一致）。
    /// 旧实现只试 kAXSize 且丢弃结果，导致 Electron 应用窗口只居中、不放大（用户反馈
    /// "设置了自动平铺但不生效"的根因）。
    /// 返回 ResizeOutcome：.axSize（kAXSize 直接成功）/ .axFrame（回退成功，Electron 走这条）/
    /// .failed（两条都失败）。调用方据此判断是否放大成功，日志也可区分走的是哪条路径。
    @discardableResult
    private func resizeWindowWithFallback(_ windowElement: AXUIElement, newSize: CGSize) -> ResizeOutcome {
        if setSizeAttribute(kAXSizeAttribute as CFString, value: newSize, on: windowElement) {
            return .axSize
        }
        if let pos = pointAttribute(kAXPositionAttribute as CFString, on: windowElement) {
            if setRectAttribute("AXFrame" as CFString, value: CGRect(origin: pos, size: newSize), on: windowElement) {
                return .axFrame
            }
        }
        return .failed
    }

    private func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        element.axBool(attribute)
    }

    private func isFullscreenWindow(_ windowElement: AXUIElement) -> Bool {
        // Primary signal if available.
        if boolAttribute("AXFullScreen" as CFString, on: windowElement) == true {
            return true
        }

        // Fallback for apps/spaces that don't expose AXFullScreen reliably.
        // Try both coordinate interpretations against every screen and accept the best match.
        guard
            let rawPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            return false
        }

        let primaryTopY = primaryScreenTopY()
        for screen in NSScreen.screens {
            let screenFrame = screen.frame

            for space in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] {
                let rect = rawToGlobalRect(space: space, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
                if isFullscreenLike(windowFrame: rect, screenFrame: screenFrame) {
                    return true
                }
            }
        }

        return false
    }

    private func isFullscreenLike(windowFrame: CGRect, screenFrame: CGRect) -> Bool {
        // Be tolerant of minor off-by-few-pixels differences (rounded corners, scaling, etc.).
        let tol: CGFloat = 6.0
        let posMatch = abs(windowFrame.minX - screenFrame.minX) <= tol &&
            abs(windowFrame.minY - screenFrame.minY) <= tol
        let sizeMatch = abs(windowFrame.width - screenFrame.width) <= tol &&
            abs(windowFrame.height - screenFrame.height) <= tol

        return posMatch && sizeMatch
    }

    private func detectWindowContext(rawPosition: CGPoint, windowSize: CGSize, pid: pid_t?, primaryTopY: CGFloat) -> WindowContext? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let cachedScreen: NSScreen? = {
            guard let pid, let id = cachedDisplayByPID[pid] else { return nil }
            return screens.first(where: { displayID(for: $0) == id })
        }()
        let cachedSpace: RawSpace? = {
            guard let pid else { return nil }
            return cachedSpaceByPID[pid]
        }()

        // === 中心点归属优先（需求4：app 原先在哪屏就在哪屏）===
        // globalBottomLeft / globalTopLeft 的全局 rect 不依赖屏幕 frame，可稳定求窗口中心，
        // 用 ScreenSelection 纯函数决定它属于哪屏。命中即锁定屏幕，再在该屏上逐空间评分。
        if let locked = lockScreenByWindowCenter(
            rawPosition: rawPosition, windowSize: windowSize, pid: pid, screens: screens,
            primaryTopY: primaryTopY, cachedScreen: cachedScreen, cachedSpace: cachedSpace
        ) {
            return locked
        }

        // === 回退：旧的逐屏 × 逐空间最大重叠评分 ===
        var best: ContextCandidate?

        for screen in screens {
            let screenFrame = screen.frame

            for space in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] {
                let globalRect = rawToGlobalRect(space: space, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
                let overlap = globalRect.intersection(screenFrame).area
                let dist2 = distanceSquaredFromRectCenter(globalRect, to: screenFrame)
                consider(
                    candidate: ContextCandidate(screen: screen, space: space, globalRect: globalRect, overlap: overlap, distance2: dist2),
                    best: &best,
                    cachedScreen: cachedScreen,
                    cachedSpace: cachedSpace
                )
            }
        }

        if let best {
            // If we had any meaningful overlap, treat this as reliable and update cache.
            if let pid, best.overlap > 1 {
                if let id = displayID(for: best.screen) {
                    cachedDisplayByPID[pid] = id
                }
                cachedSpaceByPID[pid] = best.space
            } else if cachedScreen != nil, let cachedScreen, let cachedSpace {
                let screenFrame = cachedScreen.frame
                let globalRect = rawToGlobalRect(space: cachedSpace, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
                return WindowContext(screen: cachedScreen, space: cachedSpace, overlap: 0, currentGlobalRect: globalRect)
            }
            return WindowContext(screen: best.screen, space: best.space, overlap: best.overlap, currentGlobalRect: best.globalRect)
        }
        return nil
    }

    /// 用窗口中心点（globalBottomLeft / globalTopLeft 两种全局空间）决定它属于哪个屏幕。
    /// 锁定屏幕后，在该屏上逐空间评分选最优 RawSpace，并更新缓存。
    /// 返回 nil 表示中心归属无法确定（应回退到最大重叠评分）。
    private func lockScreenByWindowCenter(
        rawPosition: CGPoint,
        windowSize: CGSize,
        pid: pid_t?,
        screens: [NSScreen],
        primaryTopY: CGFloat,
        cachedScreen: NSScreen?,
        cachedSpace: RawSpace?
    ) -> WindowContext? {
        // 这两个空间的全局 rect 不依赖屏幕 frame，可稳定计算窗口中心。
        let globalSpaces: [RawSpace] = [.globalBottomLeft, .globalTopLeft]
        // 用任一稳定参照屏求 local 空间的中心候选（local 转换依赖 screenFrame，
        // 但对“窗口中心在哪屏”的判定影响很小，用缓存屏/主屏作参照即可）。
        let refScreen = cachedScreen ?? screens.first(where: { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }) ?? screens[0]
        let localSpaces: [RawSpace] = [.localBottomLeft, .localTopLeft]

        let screenFrames = screens.map { $0.frame }

        // 收集所有 (space, 该空间下的窗口全局中心) 候选。
        var centerCandidates: [(space: RawSpace, center: CGPoint)] = []
        for space in globalSpaces {
            let r = rawToGlobalRect(space: space, screenFrame: refScreen.frame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
            centerCandidates.append((space, CGPoint(x: r.midX, y: r.midY)))
        }
        for space in localSpaces {
            let r = rawToGlobalRect(space: space, screenFrame: refScreen.frame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
            centerCandidates.append((space, CGPoint(x: r.midX, y: r.midY)))
        }

        // 对每个候选中心，看它属于哪屏；多个 space 投票一致即采纳该屏。
        // （不同 space 给出的中心可能不同，但若多数一致，说明窗口确实在该屏。）
        var screenVotes: [CGDirectDisplayID: Int] = [:]
        var chosenScreen: NSScreen?
        for cand in centerCandidates {
            guard let idx = ScreenSelection.screenIndex(forCenter: cand.center, inScreens: screenFrames) else { continue }
            let s = screens[idx]
            chosenScreen = s
            if let id = displayID(for: s) {
                screenVotes[id, default: 0] += 1
            }
        }

        // 取得票最多的屏幕（至少 1 票）。
        let winnerID = screenVotes.max { $0.value < $1.value }?.key
        let lockedScreen: NSScreen? = {
            if let winnerID { return screens.first(where: { displayID(for: $0) == winnerID }) }
            return chosenScreen
        }()
        guard let lockedScreen else { return nil }

        // 在锁定屏幕上逐空间评分选最优 RawSpace。
        let screenFrame = lockedScreen.frame
        var best: ContextCandidate?
        for space in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] {
            let globalRect = rawToGlobalRect(space: space, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
            let overlap = globalRect.intersection(screenFrame).area
            let dist2 = distanceSquaredFromRectCenter(globalRect, to: screenFrame)
            consider(
                candidate: ContextCandidate(screen: lockedScreen, space: space, globalRect: globalRect, overlap: overlap, distance2: dist2),
                best: &best,
                cachedScreen: cachedScreen,
                cachedSpace: cachedSpace
            )
        }
        guard let best else { return nil }

        // 更新缓存（中心归属是强信号，即便重叠小也采纳）。
        if let pid {
            if let id = displayID(for: lockedScreen) {
                cachedDisplayByPID[pid] = id
            }
            cachedSpaceByPID[pid] = best.space
        }
        return WindowContext(screen: lockedScreen, space: best.space, overlap: best.overlap, currentGlobalRect: best.globalRect)
    }

    private func detectWindowContextUsingCG(
        windowElement: AXUIElement,
        pid: pid_t,
        rawPosition: CGPoint,
        windowSize: CGSize,
        primaryTopY: CGFloat
    ) -> WindowContext? {
        let fallbackContext = detectWindowContext(
            rawPosition: rawPosition,
            windowSize: windowSize,
            pid: pid,
            primaryTopY: primaryTopY
        )
        let preferredDisplayID = fallbackContext.flatMap { displayID(for: $0.screen) }

        guard
            ScreenCapturePermission.ensureAuthorized(prompt: false),
            let cgRect = cgWindowBounds(
                windowID: windowIDAttribute(on: windowElement),
                pid: pid,
                expectedSize: windowSize,
                preferredDisplayID: preferredDisplayID
            ),
            let screenPick = pickScreenForCGRect(cgRect)
        else {
            return nil
        }

        let screen = screenPick.screen
        let screenFrame = screen.frame

        // Convert CG global rect (origin at top-left of primary, y grows down) to Cocoa global rect.
        let cocoaRect = cocoaRectFromCGWindowBounds(cgRect, screen: screen, primaryTopY: primaryTopY)

        var best: (space: RawSpace, globalRect: CGRect, error: CGFloat)?
        for space in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] {
            let globalRect = rawToGlobalRect(space: space, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
            let err = rectMatchError(globalRect, cocoaRect)
            if let best, best.error <= err { continue }
            best = (space, globalRect, err)
        }
        guard let best else { return nil }
        DiagnosticLog.debug("detectCG: pid=\(pid) cgRect=\(cgRect) cocoaRect=\(cocoaRect) pickedSpace=\(best.space) err=\(best.error)")

        if let id = displayID(for: screen) {
            cachedDisplayByPID[pid] = id
        }
        cachedSpaceByPID[pid] = best.space

        return WindowContext(screen: screen, space: best.space, overlap: screenPick.area, currentGlobalRect: best.globalRect)
    }

    private func rectMatchError(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) +
            abs(a.minY - b.minY) +
            abs(a.width - b.width) +
            abs(a.height - b.height)
    }

    private func windowIDAttribute(on window: AXUIElement) -> CGWindowID? {
        // AXWindowNumber 为 CFNumber；通过共享扩展以 64 位安全方式读取正整数。
        // CGWindowID 是 UInt32，故只接受落在 1...UInt32.max 的值（窗口编号总在此范围内）。
        guard let n = window.axPositiveInteger("AXWindowNumber" as CFString),
              (1...Int(UInt32.max)).contains(n)
        else { return nil }
        return CGWindowID(UInt32(n))
    }

    private func cgWindowBounds(
        windowID: CGWindowID?,
        pid: pid_t,
        expectedSize: CGSize,
        preferredDisplayID: CGDirectDisplayID?
    ) -> CGRect? {
        if let windowID {
            let options: CGWindowListOption = [.optionIncludingWindow]
            if
                let list = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
                let info = list.first,
                let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                ownerPID == Int(pid),
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: boundsDict)
            {
                return rect
            }
        }

        // Some apps do not expose AXWindowNumber (e.g. certain Office windows).
        // Fallback: pick the best on-screen window for this PID by closest size.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var bestRect: CGRect?
        var bestScore: CGFloat = .greatestFiniteMagnitude

        let preferredDisplayBounds: CGRect? = {
            guard let preferredDisplayID else { return nil }
            return CGDisplayBounds(preferredDisplayID)
        }()

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID == Int(pid) else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }

            var score = abs(rect.width - expectedSize.width) + abs(rect.height - expectedSize.height)

            if let preferredDisplayBounds {
                let overlap = rect.intersection(preferredDisplayBounds).area
                if overlap <= 1 {
                    score += 10_000
                } else {
                    let rectArea = max(1, rect.area)
                    let outsideRatio = max(0, min(1, (rectArea - overlap) / rectArea))
                    score += outsideRatio * 500
                }
            }

            if score < bestScore {
                bestScore = score
                bestRect = rect
            }
        }

        return bestRect
    }

    private func pickScreenForCGRect(_ cgRect: CGRect) -> (screen: NSScreen, area: CGFloat)? {
        let screensAndFrames = NSScreen.screens.compactMap { screen -> (NSScreen, CGRect)? in
            guard let id = displayID(for: screen) else { return nil }
            return (screen, CGDisplayBounds(id))
        }
        guard
            let match = WindowScreenOverlapSelection.bestMatch(
                for: cgRect,
                in: screensAndFrames.map(\.1)
            ),
            screensAndFrames.indices.contains(match.index)
        else {
            // Zero-overlap evidence is not a screen selection signal.
            return nil
        }
        return (screensAndFrames[match.index].0, match.area)
    }

    private func cocoaRectFromCGWindowBounds(_ cgRect: CGRect, screen: NSScreen, primaryTopY: CGFloat) -> CGRect {
        guard let id = displayID(for: screen) else {
            let y = primaryTopY - cgRect.minY - cgRect.height
            return CGRect(x: cgRect.minX, y: y, width: cgRect.width, height: cgRect.height)
        }
        let cgDisplay = CGDisplayBounds(id)
        let screenFrame = screen.frame
        let cocoaX = screenFrame.minX + (cgRect.minX - cgDisplay.minX)
        let cocoaY = primaryTopY - cgRect.minY - cgRect.height
        return CGRect(x: cocoaX, y: cocoaY, width: cgRect.width, height: cgRect.height)
    }

    private func consider(candidate: ContextCandidate, best: inout ContextCandidate?, cachedScreen: NSScreen?, cachedSpace: RawSpace?) {
        let overlapTol: CGFloat = 0.5
        let cacheBonus: CGFloat = 0.25

        // Score by overlap first; break ties by distance; preserve the historic tie-break of preferring top-left.
        func adjustedOverlap(_ c: ContextCandidate) -> CGFloat {
            if let cachedScreen, let cachedSpace,
               cachedScreen == c.screen, cachedSpace == c.space
            {
                return c.overlap + cacheBonus
            }
            return c.overlap
        }

        if let currentBest = best {
            let candOverlap = adjustedOverlap(candidate)
            let bestOverlap = adjustedOverlap(currentBest)

            if candOverlap > bestOverlap + overlapTol {
                best = candidate
                return
            }

            let diff = candOverlap > bestOverlap ? (candOverlap - bestOverlap) : (bestOverlap - candOverlap)
            if diff <= overlapTol {
                if candidate.distance2 + 0.5 < currentBest.distance2 {
                    best = candidate
                    return
                }
                // If still tied, prefer top-left (original behavior).
                let distDiff = candidate.distance2 > currentBest.distance2 ? (candidate.distance2 - currentBest.distance2) : (currentBest.distance2 - candidate.distance2)
                if distDiff <= 0.5 {
                    if isBottomLeft(space: currentBest.space), isTopLeft(space: candidate.space) {
                        best = candidate
                        return
                    }
                }
            }

            // If both overlaps are zero, pick the closest screen.
            if currentBest.overlap <= overlapTol, candidate.overlap <= overlapTol {
                if candidate.distance2 + 0.5 < currentBest.distance2 {
                    best = candidate
                    return
                }
            }
            return
        }

        best = candidate
    }

    private func toAXOrigin(bottomLeftOrigin: CGPoint, windowSize: CGSize, screenFrame: CGRect, space: RawSpace, primaryTopY: CGFloat) -> CGPoint {
        switch space {
        case .globalBottomLeft:
            return CGPoint(x: bottomLeftOrigin.x.rounded(), y: bottomLeftOrigin.y.rounded())
        case .globalTopLeft:
            let y = (primaryTopY - bottomLeftOrigin.y - windowSize.height).rounded()
            return CGPoint(x: bottomLeftOrigin.x.rounded(), y: y)
        case .localBottomLeft:
            let x = (bottomLeftOrigin.x - screenFrame.minX).rounded()
            let y = (bottomLeftOrigin.y - screenFrame.minY).rounded()
            return CGPoint(x: x, y: y)
        case .localTopLeft:
            let x = (bottomLeftOrigin.x - screenFrame.minX).rounded()
            let y = (screenFrame.maxY - bottomLeftOrigin.y - windowSize.height).rounded()
            return CGPoint(x: x, y: y)
        }
    }

    private func rawToGlobalRect(space: RawSpace, screenFrame: CGRect, rawPosition: CGPoint, windowSize: CGSize, primaryTopY: CGFloat) -> CGRect {
        switch space {
        case .globalBottomLeft:
            return CGRect(origin: rawPosition, size: windowSize)
        case .globalTopLeft:
            let convertedBottomY = primaryTopY - rawPosition.y - windowSize.height
            return CGRect(x: rawPosition.x, y: convertedBottomY, width: windowSize.width, height: windowSize.height)
        case .localBottomLeft:
            return CGRect(
                x: screenFrame.minX + rawPosition.x,
                y: screenFrame.minY + rawPosition.y,
                width: windowSize.width,
                height: windowSize.height
            )
        case .localTopLeft:
            let x = screenFrame.minX + rawPosition.x
            let y = screenFrame.maxY - rawPosition.y - windowSize.height
            return CGRect(x: x, y: y, width: windowSize.width, height: windowSize.height)
        }
    }

    private func tileReachedTarget(
        _ windowElement: AXUIElement,
        pid: pid_t?,
        context: WindowContext,
        space: RawSpace? = nil,
        primaryTopY: CGFloat,
        targetFrame: CGRect
    ) -> Bool {
        if
            let pid,
            ScreenCapturePermission.ensureAuthorized(prompt: false),
            let cgRect = cgWindowBounds(
                windowID: windowIDAttribute(on: windowElement),
                pid: pid,
                expectedSize: targetFrame.size,
                preferredDisplayID: displayID(for: context.screen)
            ),
            let screenPick = pickScreenForCGRect(cgRect)
        {
            let cocoaRect = cocoaRectFromCGWindowBounds(cgRect, screen: screenPick.screen, primaryTopY: primaryTopY)
            if frameSatisfiesFinalTiledTarget(cocoaRect, target: targetFrame) {
                return true
            }
            DiagnosticLog.debug("tileReachedTarget: CG mismatch, falling back to AX pid=\(pid) cgRect=\(cgRect) target=\(targetFrame)")
        }

        guard
            let rawPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let rawSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            return false
        }

        let currentFrame = rawToGlobalRect(
            space: space ?? context.space,
            screenFrame: context.screen.frame,
            rawPosition: rawPosition,
            windowSize: rawSize,
            primaryTopY: primaryTopY
        )

        return frameSatisfiesFinalTiledTarget(currentFrame, target: targetFrame)
    }

    private func frameSatisfiesFinalTiledTarget(_ frame: CGRect, target: CGRect) -> Bool {
        WindowGeometry.frameSatisfiesFinalTiledTarget(frame, target: target)
    }

    private func isTopLeft(space: RawSpace) -> Bool {
        switch space {
        case .globalTopLeft, .localTopLeft:
            return true
        default:
            return false
        }
    }

    private func isBottomLeft(space: RawSpace) -> Bool {
        switch space {
        case .globalBottomLeft, .localBottomLeft:
            return true
        default:
            return false
        }
    }

    private func prioritizedSpaces(primary: RawSpace) -> [RawSpace] {
        var ordered: [RawSpace] = [primary]
        for candidate in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] where !ordered.contains(where: { $0 == candidate }) {
            ordered.append(candidate)
        }
        return ordered
    }

    private func effectiveVisibleFrame(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let insets = WindowGeometry.insetsFromVisibleFrame(frame: frame, visible: visible)
        return CGRect(
            x: frame.minX + insets.left,
            y: frame.minY + insets.bottom,
            width: frame.width - insets.left - insets.right,
            height: frame.height - insets.top - insets.bottom
        )
    }

    private func distanceSquaredFromRectCenter(_ rect: CGRect, to bounds: CGRect) -> CGFloat {
        let cx = rect.midX
        let cy = rect.midY
        let nx = clamp(cx, min: bounds.minX, max: bounds.maxX)
        let ny = clamp(cy, min: bounds.minY, max: bounds.maxY)
        let dx = cx - nx
        let dy = cy - ny
        return dx * dx + dy * dy
    }

    private func clamp(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        Swift.max(lowerBound, Swift.min(value, upperBound))
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Records a coordinate space only after a write was read back successfully.
    /// This lets the synchronous fallback loop teach subsequent operations which
    /// candidate actually matched the application's AX convention.
    private func rememberResolvedContext(pid: pid_t?, screen: NSScreen, space: RawSpace) {
        guard let pid else { return }
        cachedSpaceByPID[pid] = space
        if let displayID = displayID(for: screen) {
            cachedDisplayByPID[pid] = displayID
        }
    }

    private func primaryScreenTopY() -> CGFloat {
        // Primary display's top edge in Cocoa global coordinates (also equals its height when minY == 0).
        let screens = NSScreen.screens
        let primary = screens.first(where: { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 })
        return (primary ?? NSScreen.main ?? screens.first)?.frame.maxY ?? 0
    }
}

private extension CGRect {
    var area: CGFloat {
        if isNull || isEmpty {
            return 0
        }
        return width * height
    }
}
